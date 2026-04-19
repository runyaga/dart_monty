import 'dart:async';

import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/bridge_logger.dart';
import 'package:dart_monty/src/default_monty_bridge.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/host_param.dart';
import 'package:dart_monty/src/host_param_type.dart';
import 'package:dart_monty/src/introspection_functions.dart';
import 'package:dart_monty/src/monty_bridge.dart';
import 'package:dart_monty/src/monty_bridge_session_state.dart';
import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/plugin_registry.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';

// ---------------------------------------------------------------------------
// MontyBridgeSession
// ---------------------------------------------------------------------------

/// High-level agent session — stateful Python execution with tools and plugins.
///
/// Combines `MontyBridge`, `PluginRegistry`, and OS providers into a single
/// API. Both execution modes are backed by [ReplPlatform], which adapts
/// [MontyRepl] to the [MontyPlatform] interface accepted by
/// [DefaultMontyBridge]. All state (variables, functions, classes, modules)
/// persists natively in the Rust REPL heap across `execute()` calls — no
/// Dart-side serialization round-trip.
///
/// Two execution modes:
///
/// **Shared interpreter** (default): One [MontyRepl] across all `execute()`
/// calls. Variables, functions, classes, and modules defined in one call are
/// available in every subsequent call. Fast; suitable for interactive REPLs
/// and LLM tool-call loops.
///
/// **Fresh sandbox** (`sandbox: true`): Each `execute()` creates and disposes
/// a fresh [MontyRepl]. State does not persist between calls. Safe for
/// host functions that do async I/O (HTTP, SSE streaming, etc.) at the cost
/// of ~2-5ms interpreter creation overhead per call.
///
/// ```dart
/// // Shared interpreter (default) — full state persistence
/// final session = MontyBridgeSession(os: defaultSandboxOsHandler());
/// await session.execute('x = 42');
/// final result = await session.execute('x + 1'); // 43
/// await session.execute('def add(a, b): return a + b');
/// final r = await session.execute('add(3, 4)'); // 7
///
/// // Fresh sandbox — isolated per call, safe for async I/O host functions
/// final session = MontyBridgeSession(
///   sandbox: true,
///   plugins: [SoliplexPlugin(connections: {...})],
/// );
/// await session.execute('r = soliplex_new_thread("s", "r", "Hi")');
/// await session.execute('r2 = soliplex_reply_thread(...)'); // no crash
/// ```
class MontyBridgeSession {
  /// Creates an agent session.
  ///
  /// When [sandbox] is true, each `execute()` call creates a fresh [MontyRepl].
  /// State does not persist between calls. Safe for host functions that do
  /// long-running async I/O (#271).
  ///
  /// When [sandbox] is false (default), a single [MontyRepl] is reused across
  /// all calls — all state persists natively in the Rust heap.
  MontyBridgeSession({
    OsCallHandler? os,
    Map<String, OsCallHandler>? osHandlers,
    List<MontyPlugin>? plugins,
    BridgeLogger? logger,
    bool sandbox = false,
  }) : assert(
         os == null || osHandlers == null,
         'Pass either os or osHandlers, not both.',
       ),
       _os = os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
       _plugins = plugins,
       _logger = logger,
       _sandbox = sandbox {
    if (!sandbox) {
      // Shared mode: create persistent REPL-backed interpreter.
      // ReplPlatform retains all state (variables, functions, classes) natively
      // in the Rust heap across execute() calls — no Dart-side serialization.
      _sharedRepl = MontyRepl();
      _sharedPlatform = ReplPlatform(repl: _sharedRepl!);
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

  final OsCallHandler? _os;
  final List<MontyPlugin>? _plugins;
  final BridgeLogger? _logger;
  final bool _sandbox;

  // Shared mode state.
  MontyRepl? _sharedRepl;
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
  /// Always emits an empty map — state persists natively in the Rust REPL
  /// heap and is not mirrored to Dart. Kept for API compatibility.
  ReadonlySignal<Map<String, Object?>> get sessionStateSignal =>
      _sessionStateSignal;

  /// Whether this session creates a fresh interpreter per `execute()`.
  bool get isSandboxMode => _sandbox;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('MontyBridgeSession has been disposed');
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
    if (_disposed) throw StateError('MontyBridgeSession has been disposed');

    if (_sandbox) {
      return _executeSandboxed(code);
    }

    return _executeShared(code);
  }

  /// Executes [code] and returns the stream of bridge events.
  ///
  /// Only available in shared mode. In sandbox mode, use `execute()`.
  Stream<BridgeEvent> executeStream(String code) {
    if (_disposed) throw StateError('MontyBridgeSession has been disposed');
    if (_sandbox) {
      throw UnsupportedError(
        'executeStream() is not supported in sandbox mode. '
        'Use execute() instead.',
      );
    }

    return _executeStreamShared(code);
  }

  /// Clears all persisted Python state.
  ///
  /// In shared mode, recreates the full interpreter stack ([MontyRepl],
  /// [ReplPlatform], [DefaultMontyBridge], and [PluginRegistry]) so the next
  /// `execute()` call starts with empty Python globals. Plugins are
  /// re-attached on the next `execute()` call.
  ///
  /// In sandbox mode, each call already uses a fresh interpreter — this is
  /// a no-op.
  void clearState() {
    if (_disposed) throw StateError('MontyBridgeSession has been disposed');
    _sessionStateSignal.value = {};
    if (!_sandbox && _sharedBridge != null) {
      final oldPlatform = _sharedPlatform;
      final oldRegistry = _sharedRegistry;

      _sharedRepl = MontyRepl();
      _sharedPlatform = ReplPlatform(repl: _sharedRepl!);
      _sharedBridge = DefaultMontyBridge(
        platform: _sharedPlatform!,
        useFutures: false,
        logger: _logger,
      );
      _registerStateHostFunctions(_sharedBridge!);
      _extraFunctions.forEach(_sharedBridge!.register);

      _sharedRegistry = PluginRegistry();
      if (_plugins != null) {
        _plugins.forEach(_sharedRegistry!.register);
      }
      _sharedAttached = false;

      if (oldRegistry != null) unawaited(oldRegistry.disposeAll());
      unawaited(oldPlatform?.dispose());
    }
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_sharedRegistry != null) await _sharedRegistry!.disposeAll();
    _sharedBridge?.dispose();
    _schemaBridge?.dispose();
    await _sharedPlatform?.dispose();
    await _sharedRepl?.dispose();
    _sessionStateSignal.dispose();
  }

  Stream<BridgeEvent> _executeStreamShared(String code) async* {
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(_sharedBridge!, baseOs: _os);
      _sharedAttached = true;
    }
    yield* _sharedBridge!.execute(code);
  }

  // ---------------------------------------------------------------------------
  // Shared mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeShared(String code) async {
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(_sharedBridge!, baseOs: _os);
      _sharedAttached = true;
    }
    final events = await _sharedBridge!.execute(code).toList();

    return extractBridgeResult(events, 0);
  }

  // ---------------------------------------------------------------------------
  // Sandbox mode execution
  // ---------------------------------------------------------------------------

  Future<MontyResult> _executeSandboxed(String code) async {
    final repl = MontyRepl();
    final platform = ReplPlatform(repl: repl);
    final b = _buildBridge(platform: platform);

    final registry = PluginRegistry();
    if (_plugins != null) {
      _plugins.forEach(registry.register);
    }
    await registry.attachTo(b, baseOs: _os);

    try {
      final events = await b.execute(code).toList();

      return extractBridgeResult(events, 0);
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
      platform: platform ?? ReplPlatform(repl: MontyRepl()),
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
            name: restoreFn,
            description: 'Internal: restore session state',
          ),
          handler: (_) async => _sessionStateSignal.value,
        ),
      )
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: persistFn,
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
    // registered directly via MontyBridgeSession.register() without going
    // through
    // PluginRegistry.attachTo(). When a PluginRegistry IS later attached,
    // re-registration is a safe no-op (bridge.register() overwrites by name,
    // _categoryIndex is a Set so the duplicate category entry is ignored).
    for (final fn in buildIntrospectionFunctions(target)) {
      target.register(fn, category: introspectionCategory);
    }
  }
}
