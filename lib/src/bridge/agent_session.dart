import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/monty.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:dart_monty/src/platform/code_capture.dart' as code_capture;
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_value.dart';
import 'package:signals_core/signals_core.dart';

const _restoreFn = '__restore_state__';
const _persistFn = '__persist_state__';

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

// ---------------------------------------------------------------------------
// Top-level helpers — pure utilities that do not need AgentSession state.
// ---------------------------------------------------------------------------

/// Extracts the terminal [MontyResult] from a completed bridge event list.
/// Throws [StateError] if no [BridgeRunFinished]/[BridgeRunError] event exists.
MontyResult _extractBridgeResult(List<BridgeEvent> events) {
  for (final event in events.reversed) {
    if (event is BridgeRunFinished) {
      return MontyResult(
        value: MontyValue.fromDart(event.value),
        usage: _zeroUsage,
        printOutput: event.printOutput,
      );
    }
    if (event is BridgeRunError) {
      return MontyResult(
        value: const MontyNull(),
        error: event.exception ?? MontyException(message: event.message),
        usage: _zeroUsage,
        printOutput: event.printOutput,
      );
    }
  }

  throw StateError('No terminal event in bridge execution');
}

/// Generates the `__restore_state__` preamble that loads [state] into Python.
String _generateRestoreCode(Map<String, Object?> state) {
  final buf = StringBuffer('__d = $_restoreFn()');
  for (final key in state.keys) {
    buf.write('\n$key = __d["$key"]');
  }

  return buf.toString();
}

/// Generates the `__persist_state__` epilogue that captures [userCode]
/// assignment targets plus existing [state] keys back to Dart.
String _generatePersistCode(String userCode, Map<String, Object?> state) {
  final names = <String>{
    ...state.keys,
    ...code_capture.extractAssignmentTargets(userCode),
  };

  if (names.isEmpty) return '$_persistFn({})';

  final buf = StringBuffer('__d2 = {}');
  for (final name in names) {
    buf
      ..write('\ntry:')
      ..write('\n    __d2["$name"] = $name')
      ..write('\nexcept NameError:')
      ..write('\n    pass');
  }
  buf.write('\n$_persistFn(__d2)');

  return buf.toString();
}

/// Wraps [userCode] with restore/persist state bookkeeping, preserving
/// the last-expression result capture.
String _wrapWithStateCode(String userCode, Map<String, Object?> state) {
  final restore = _generateRestoreCode(state);
  final persist = _generatePersistCode(userCode, state);
  final (processed, hasResult) = code_capture.captureLastExpression(userCode);

  final buf = StringBuffer(restore)
    ..write('\n')
    ..write(processed)
    ..write('\n')
    ..write(persist);

  if (hasResult) buf.write('\n__r');

  return buf.toString();
}

// ---------------------------------------------------------------------------
// AgentSession
// ---------------------------------------------------------------------------

/// High-level agent session — stateful Python execution with tools and plugins.
///
/// Combines `MontyBridge`, `PluginRegistry`, OS providers, and variable
/// persistence into a single API. Variables persist across `execute()` calls
/// via Dart-side state serialization — not interpreter reuse.
///
/// Two execution modes:
///
/// **Shared interpreter** (default): One interpreter across all `execute()`
/// calls. Fast for lightweight host functions. May crash on FFI if host
/// functions do long-running async I/O (see #271).
///
/// **Fresh sandbox** (`sandbox: true`): Each `execute()` creates and disposes
/// a fresh interpreter. State persists via `__restore_state__` /
/// `__persist_state__` host functions. Safe for host functions that do
/// async I/O (HTTP, SSE streaming, etc.) at the cost of ~2-5ms interpreter
/// creation overhead per call.
///
/// ```dart
/// // Shared interpreter (default) — fast, light host functions
/// final session = AgentSession(os: OsProvider());
/// await session.execute('x = 42');
/// final result = await session.execute('x + 1'); // 43
///
/// // Fresh sandbox — safe for async I/O host functions
/// final session = AgentSession(
///   sandbox: true,
///   plugins: [SoliplexPlugin(connections: {...})],
/// );
/// await session.execute('r = soliplex_new_thread("s", "r", "Hi")');
/// await session.execute('r2 = soliplex_reply_thread(...)'); // no crash
/// ```
class AgentSession {
  /// Creates an agent session.
  ///
  /// When [sandbox] is true, each `execute()` call creates a fresh
  /// interpreter. This avoids FFI state corruption when host functions
  /// do long-running async I/O (#271). State persists via host functions.
  ///
  /// When [sandbox] is false (default), a single interpreter is reused
  /// across calls for maximum performance.
  AgentSession({
    OsProvider? os,
    List<MontyPlugin>? plugins,
    BridgeLogger? logger,
    bool sandbox = false,
  }) : _os = os,
       _plugins = plugins,
       _logger = logger,
       _sandbox = sandbox {
    if (!sandbox) {
      // Shared mode: create persistent interpreter.
      _sharedMonty = Monty(os: os);
      _sharedBridge = DefaultMontyBridge(
        platform: _sharedMonty!.platform,
        useFutures: false,
        logger: logger,
      );
      // OS registration is deferred to the first execute() call via
      // PluginRegistry.attachTo(bridge, baseOs: _os).
      _registerStateHostFunctions(_sharedBridge!);

      _sharedRegistry = PluginRegistry();
      if (plugins != null) {
        plugins.forEach(_sharedRegistry!.register);
      }
    } else {
      // Sandbox mode: build a schema bridge once for introspection.
      _schemaBridge = _buildBridge();
    }
  }

  final OsProvider? _os;
  final List<MontyPlugin>? _plugins;
  final BridgeLogger? _logger;
  final bool _sandbox;

  // Shared mode state.
  Monty? _sharedMonty;
  DefaultMontyBridge? _sharedBridge;
  PluginRegistry? _sharedRegistry;
  bool _sharedAttached = false;

  // Sandbox mode schema bridge (no platform, just for introspection).
  DefaultMontyBridge? _schemaBridge;

  bool _disposed = false;
  final Signal<Map<String, Object?>> _sessionStateSignal =
      signal<Map<String, Object?>>({});
  final List<HostFunction> _extraFunctions = [];

  /// All registered tool schemas — feed these to an LLM as tool definitions.
  List<HostFunctionSchema> get schemas =>
      (_sharedBridge ?? _schemaBridge)?.schemas ?? [];

  /// The underlying bridge — for advanced use (middleware, direct execute).
  ///
  /// In sandbox mode, returns a schema-only bridge (no platform). Use
  /// `execute()` for actual code execution.
  MontyBridge? get bridge => _sharedBridge ?? _schemaBridge;

  /// The current persisted Python state.
  Map<String, Object?> get state => Map.from(_sessionStateSignal.value);

  /// Reactive persisted Python state.
  ///
  /// Emits a new snapshot after every `execute()` call that assigns
  /// variables in Python (via `__persist_state__`). Subscribe via [effect]
  /// to react to variable changes without polling [state]:
  ///
  /// ```dart
  /// effect(() {
  ///   final s = session.sessionStateSignal.value;
  ///   if (s.containsKey('result')) print(s['result']);
  /// });
  /// ```
  ReadonlySignal<Map<String, Object?>> get sessionStateSignal =>
      _sessionStateSignal;

  /// Whether this session creates a fresh interpreter per `execute()`.
  bool get isSandboxMode => _sandbox;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('AgentSession has been disposed');
    if (_sharedBridge != null) {
      _sharedBridge!.register(function);
    }
    _extraFunctions.add(function);
  }

  /// Executes Python [code] with state persistence and full tool access.
  ///
  /// Variables defined in [code] persist for subsequent `execute()` calls.
  /// All registered host functions and plugins are callable from Python.
  ///
  /// In sandbox mode, creates a fresh interpreter per call.
  Future<MontyResult> execute(String code) {
    if (_disposed) throw StateError('AgentSession has been disposed');

    if (_sandbox) {
      return _executeSandboxed(code);
    }

    return _executeShared(code);
  }

  /// Executes [code] and returns the stream of bridge events.
  ///
  /// Only available in shared mode. In sandbox mode, use `execute()`.
  Stream<BridgeEvent> executeStream(String code) {
    if (_disposed) throw StateError('AgentSession has been disposed');
    if (_sandbox) {
      throw UnsupportedError(
        'executeStream() is not supported in sandbox mode. '
        'Use execute() instead.',
      );
    }

    return _executeStreamShared(code);
  }

  /// Clears all persisted Python state.
  void clearState() {
    if (_disposed) throw StateError('AgentSession has been disposed');
    _sessionStateSignal.value = {};
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_sharedRegistry != null) await _sharedRegistry!.disposeAll();
    _sharedBridge?.dispose();
    _schemaBridge?.dispose();
    await _sharedMonty?.dispose();
    _sessionStateSignal.dispose();
  }

  Stream<BridgeEvent> _executeStreamShared(String code) async* {
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(_sharedBridge!, baseOs: _os);
      _sharedAttached = true;
    }
    yield* _sharedBridge!.execute(
      _wrapWithStateCode(code, _sessionStateSignal.value),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeShared(String code) async {
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(_sharedBridge!, baseOs: _os);
      _sharedAttached = true;
    }
    final events = await _sharedBridge!
        .execute(_wrapWithStateCode(code, _sessionStateSignal.value))
        .toList();

    return _extractBridgeResult(events);
  }

  // ---------------------------------------------------------------------------
  // Sandbox mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeSandboxed(String code) async {
    final monty = Monty(os: _os);
    final b = _buildBridge(platform: monty.platform);

    final registry = PluginRegistry();
    if (_plugins != null) {
      _plugins.forEach(registry.register);
    }
    await registry.attachTo(b, baseOs: _os);

    try {
      final events = await b
          .execute(_wrapWithStateCode(code, _sessionStateSignal.value))
          .toList();

      return _extractBridgeResult(events);
    } finally {
      await registry.disposeAll();
      b.dispose();
      await monty.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Bridge factory
  // ---------------------------------------------------------------------------

  DefaultMontyBridge _buildBridge({MontyPlatform? platform}) {
    final b = DefaultMontyBridge(
      platform: platform ?? Monty().platform,
      useFutures: false,
      logger: _logger,
    );

    // OS registration is handled by PluginRegistry.attachTo(b, baseOs: _os).

    _registerStateHostFunctions(b);

    _extraFunctions.forEach(b.register);

    return b;
  }

  // ---------------------------------------------------------------------------
  // State host functions
  // ---------------------------------------------------------------------------

  void _registerStateHostFunctions(DefaultMontyBridge target) {
    target
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: _restoreFn,
            description: 'Internal: restore session state',
          ),
          handler: (_) async => _sessionStateSignal.value,
        ),
      )
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: _persistFn,
            description: 'Internal: persist session state',
            params: [HostParam(name: 'state', type: HostParamType.any)],
          ),
          handler: (args) async {
            final captured = args['state'];
            if (captured is Map<String, Object?>) {
              _sessionStateSignal.value = captured;
            }

            return null;
          },
        ),
      );
  }
}
