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

const _restoreFn = '__restore_state__';
const _persistFn = '__persist_state__';

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
      if (os != null) _sharedBridge!.registerOs(os);
      _registerStateHostFunctions(_sharedBridge!);

      if (plugins != null && plugins.isNotEmpty) {
        _sharedRegistry = PluginRegistry();
        plugins.forEach(_sharedRegistry!.register);
      }
    } else {
      // Sandbox mode: build a schema bridge once for introspection.
      _schemaBridge = _buildBridge();
    }
  }

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

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
  Map<String, Object?> _sessionState = {};
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
  Map<String, Object?> get state => Map.from(_sessionState);

  /// Whether this session creates a fresh interpreter per `execute()`.
  bool get isSandboxMode => _sandbox;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    _checkNotDisposed();
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
    _checkNotDisposed();

    if (_sandbox) {
      return _executeSandboxed(code);
    }

    return _executeShared(code);
  }

  /// Executes [code] and returns the stream of bridge events.
  ///
  /// Only available in shared mode. In sandbox mode, use `execute()`.
  Stream<BridgeEvent> executeStream(String code) {
    _checkNotDisposed();
    if (_sandbox) {
      throw UnsupportedError(
        'executeStream() is not supported in sandbox mode. '
        'Use execute() instead.',
      );
    }
    final wrappedCode = _wrapWithState(code);

    return _sharedBridge!.execute(wrappedCode);
  }

  /// Clears all persisted Python state.
  void clearState() {
    _checkNotDisposed();
    _sessionState = {};
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sharedBridge?.dispose();
    _schemaBridge?.dispose();
    await _sharedMonty?.dispose();
  }

  // ---------------------------------------------------------------------------
  // Shared mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeShared(String code) async {
    await _ensureSharedAttached();

    final wrappedCode = _wrapWithState(code);
    final events = await _sharedBridge!.execute(wrappedCode).toList();

    return _extractResult(events);
  }

  Future<void> _ensureSharedAttached() async {
    if (!_sharedAttached && _sharedRegistry != null) {
      await _sharedRegistry!.attachTo(_sharedBridge!);
      _sharedAttached = true;
    }
  }

  // ---------------------------------------------------------------------------
  // Sandbox mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeSandboxed(String code) async {
    final monty = Monty(os: _os);
    final b = _buildBridge(platform: monty.platform);

    if (_plugins != null && _plugins.isNotEmpty) {
      final registry = PluginRegistry();
      _plugins.forEach(registry.register);
      await registry.attachTo(b);
    }

    try {
      final wrappedCode = _wrapWithState(code);
      final events = await b.execute(wrappedCode).toList();

      return _extractResult(events);
    } finally {
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

    if (_os != null) b.registerOs(_os);

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
          handler: (_) async => _sessionState,
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
              _sessionState = captured;
            }

            return null;
          },
        ),
      );
  }

  // ---------------------------------------------------------------------------
  // Code wrapping (state persistence)
  // ---------------------------------------------------------------------------

  String _wrapWithState(String userCode) {
    final restore = _generateRestore();
    final persist = _generatePersist(userCode);
    final (processed, hasResult) = code_capture.captureLastExpression(userCode);

    final buf = StringBuffer(restore)
      ..write('\n')
      ..write(processed)
      ..write('\n')
      ..write(persist);

    if (hasResult) {
      buf.write('\n__r');
    }

    return buf.toString();
  }

  String _generateRestore() {
    final buf = StringBuffer('__d = $_restoreFn()');
    for (final key in _sessionState.keys) {
      buf.write('\n$key = __d["$key"]');
    }

    return buf.toString();
  }

  String _generatePersist(String userCode) {
    final names = <String>{
      ..._sessionState.keys,
      ...code_capture.extractAssignmentTargets(userCode),
    };

    if (names.isEmpty) {
      return '$_persistFn({})';
    }

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

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  MontyResult _extractResult(List<BridgeEvent> events) {
    for (final event in events.reversed) {
      if (event is BridgeRunFinished) {
        final value = event.value != null
            ? MontyValue.fromDart(event.value)
            : null;

        return MontyResult(
          value: value,
          usage: _zeroUsage,
          printOutput: event.printOutput,
        );
      }
      if (event is BridgeRunError) {
        return MontyResult(
          error: event.exception ?? MontyException(message: event.message),
          usage: _zeroUsage,
          printOutput: event.printOutput,
        );
      }
    }

    // Should not happen — bridge always emits a terminal event.
    throw StateError('No terminal event in bridge execution');
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('AgentSession has been disposed');
    }
  }
}
