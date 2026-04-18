import 'dart:async';

import 'package:dart_monty/src/bridge/agent_session_state.dart';
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
import 'package:dart_monty/src/bridge/os_call/os_handlers.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';

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
/// final session = AgentSession(os: defaultSandboxOsHandler());
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

  final OsCallHandler? _os;
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
  ///
  /// In shared mode, also issues a `del` snippet against the live interpreter
  /// so tracked names disappear from Python globals, not just the Dart map.
  void clearState() {
    if (_disposed) throw StateError('AgentSession has been disposed');
    final known = _sessionStateSignal.value.keys.toList();
    _sessionStateSignal.value = {};
    if (_sharedBridge != null && known.isNotEmpty) {
      final delCode = [
        for (final k in known) 'try:\n    del $k\nexcept NameError:\n    pass',
      ].join('\n');
      // Fire-and-forget — the bridge exposes a stream; drain it so any errors
      // surface as unhandled zone errors rather than silently lingering.
      unawaited(_sharedBridge!.execute(delCode).drain());
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
    _sessionStateSignal.dispose();
  }

  Stream<BridgeEvent> _executeStreamShared(String code) async* {
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(_sharedBridge!, baseOs: _os);
      _sharedAttached = true;
    }
    // Shared mode: Rust REPL heap persists variables natively — no restore
    // preamble, so error line numbers already point at user code.
    yield* _sharedBridge!.execute(
      wrapShared(code, _sessionStateSignal.value),
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
    final snapshot = _sessionStateSignal.value;
    final events = await _sharedBridge!
        .execute(wrapShared(code, snapshot))
        .toList();

    return extractBridgeResult(events, 0);
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
      final snapshot = _sessionStateSignal.value;
      final events = await b.execute(wrapSandboxed(code, snapshot)).toList();

      return extractBridgeResult(events, restoreLineCount(snapshot));
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
    // registered directly via AgentSession.register() without going through
    // PluginRegistry.attachTo(). When a PluginRegistry IS later attached,
    // re-registration is a safe no-op (bridge.register() overwrites by name,
    // _categoryIndex is a Set so the duplicate category entry is ignored).
    for (final fn in buildIntrospectionFunctions(target)) {
      target.register(fn, category: introspectionCategory);
    }
  }
}
