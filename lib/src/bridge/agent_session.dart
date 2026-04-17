import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_logger.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/introspection_functions.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
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

// Number of lines the state restore preamble adds before user code.
//
// Structure:
//   __d = __restore_state__()   ← always 1 line
//   x = __d["x"]               ← 1 line per state variable
//   <user code>
int _restoreLineCount(Map<String, Object?> state) => 1 + state.keys.length;

/// Adjusts [e] line numbers by subtracting [offset] lines added by the state
/// restore preamble, so errors point to user code lines, not wrapped lines.
MontyException _adjustRestoreOffset(MontyException e, int offset) {
  if (offset <= 0) return e;

  return MontyException(
    message: e.message,
    filename: e.filename,
    lineNumber:
        e.lineNumber != null
            ? (e.lineNumber! - offset).clamp(1, e.lineNumber!)
            : null,
    columnNumber: e.columnNumber,
    sourceCode: e.sourceCode,
    excType: e.excType,
    traceback: e.traceback
        .where((f) => f.startLine > offset)
        .map(
          (f) => MontyStackFrame(
            filename: f.filename,
            startLine: (f.startLine - offset).clamp(1, f.startLine),
            startColumn: f.startColumn,
            endLine:
                f.endLine != null
                    ? (f.endLine! - offset).clamp(1, f.endLine!)
                    : null,
            endColumn: f.endColumn,
            frameName: f.frameName,
            previewLine: f.previewLine,
            hideCaret: f.hideCaret,
            hideFrameName: f.hideFrameName,
          ),
        )
        .toList(),
  );
}

/// Extracts the terminal [MontyResult] from a completed bridge event list,
/// adjusting exception line numbers by [restoreOffset] to account for the
/// state restore preamble injected before user code.
///
/// Throws [StateError] if no [BridgeRunFinished]/[BridgeRunError] event exists.
MontyResult _extractBridgeResult(
  List<BridgeEvent> events,
  int restoreOffset,
) {
  for (final event in events.reversed) {
    if (event is BridgeRunFinished) {
      return MontyResult(
        value: MontyValue.fromDart(event.value),
        usage: _zeroUsage,
        printOutput: event.printOutput,
      );
    }
    if (event is BridgeRunError) {
      final raw = event.exception ?? MontyException(message: event.message);
      final adjusted = _adjustRestoreOffset(raw, restoreOffset);

      return MontyResult(
        value: const MontyNone(),
        error: adjusted,
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
    ...extractAssignmentTargets(userCode),
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
  final (processed, hasResult) = captureLastExpression(userCode);

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
/// **State persistence limitation**: Variable persistence is a dart_monty
/// abstraction built on top of the Monty interpreter's value serializer.
/// Only Monty-representable types survive across calls: `int`, `float`,
/// `str`, `bool`, `list`, `dict`, `bytes`, `datetime`, `None`, and other
/// [MontyValue] subtypes. Non-representable values (functions, `re.Pattern`,
/// generators, class instances, etc.) are coerced to their string
/// representation by the Monty interpreter — they do not error or disappear,
/// but they cannot be round-tripped back to the original Python object.
/// This behavior is determined by the Monty interpreter, not dart_monty.
/// The variable capture itself is heuristic: only top-level assignment
/// targets are detected; dynamic assignments (`exec`, `setattr`) are not
/// captured.
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
      // The bridge handles OS calls — don't pass os to Monty directly.
      _sharedPlatform = createPlatformMonty();
      _sharedBridge = DefaultMontyBridge(
        platform: _sharedPlatform!,
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
  MontyPlatform? _sharedPlatform;
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
    await _sharedPlatform?.dispose();
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
    final state = _sessionStateSignal.value;
    final events = await _sharedBridge!
        .execute(_wrapWithStateCode(code, state))
        .toList();

    return _extractBridgeResult(events, _restoreLineCount(state));
  }

  // ---------------------------------------------------------------------------
  // Sandbox mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeSandboxed(String code) async {
    final platform = createPlatformMonty();
    final b = _buildBridge(platform: platform);

    final registry = PluginRegistry();
    if (_plugins != null) {
      _plugins.forEach(registry.register);
    }
    await registry.attachTo(b, baseOs: _os);

    try {
      final state = _sessionStateSignal.value;
      final events = await b
          .execute(_wrapWithStateCode(code, state))
          .toList();

      return _extractBridgeResult(events, _restoreLineCount(state));
    } finally {
      await registry.disposeAll();
      b.dispose();
      await platform.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // Bridge factory
  // ---------------------------------------------------------------------------

  DefaultMontyBridge _buildBridge({MontyPlatform? platform}) {
    final b = DefaultMontyBridge(
      platform: platform ?? createPlatformMonty(),
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

    // Register introspection builtins (e.g. help()) so they are available
    // even when no PluginRegistry is attached — e.g. when functions are
    // registered directly via AgentSession.register() without going through
    // PluginRegistry.attachTo(). When a PluginRegistry IS later attached,
    // re-registration is a safe no-op (bridge.register() overwrites by name,
    // _categoryIndex is a Set so the duplicate category entry is ignored).
    for (final fn in buildIntrospectionFunctions(target)) {
      target.register(fn, category: introspectionCategory);
    }
  }
}
