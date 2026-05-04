import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/platform.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/function_surface.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty/src/runtime/runtime_state.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

// ---------------------------------------------------------------------------
// MontyRuntime
// ---------------------------------------------------------------------------

/// High-level agent session — stateful Python execution with tools and
/// extensions.
///
/// Combines `MontyBridge`, `ExtensionCoordinator`, and OS providers into a
/// single API. Both execution modes are backed by [ReplPlatform], which adapts
/// [MontyRepl] to the [MontyPlatform] interface accepted by
/// [PlatformBridge]. All state (variables, functions, classes, modules)
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
/// final session = MontyRuntime(os: defaultSandboxOsHandler());
/// await session.execute('x = 42');
/// final result = await session.execute('x + 1'); // 43
/// await session.execute('def add(a, b): return a + b');
/// final r = await session.execute('add(3, 4)'); // 7
///
/// // Fresh sandbox — isolated per call, safe for async I/O host functions
/// final session = MontyRuntime(
///   sandbox: true,
///   extensions: [SoliplexExtension(connections: {...})],
/// );
/// await session.execute('r = soliplex_new_thread("s", "r", "Hi")');
/// await session.execute('r2 = soliplex_reply_thread(...)'); // no crash
/// ```
class MontyRuntime implements MontyRuntimeRef {
  /// Creates an agent session.
  ///
  /// When [sandbox] is true, each `execute()` call creates a fresh [MontyRepl].
  /// State does not persist between calls. Safe for host functions that do
  /// long-running async I/O (#271).
  ///
  /// When [sandbox] is false (default), a single [MontyRepl] is reused across
  /// all calls — all state persists natively in the Rust heap.
  MontyRuntime({
    OsCallHandler? os,
    Map<String, OsCallHandler>? osHandlers,
    List<MontyExtension>? extensions,
    BridgeLogger? logger,
    MontyInterceptor? interceptor,
    bool sandbox = false,
    DescriptionProvider? descriptionProvider,
  }) : assert(
         os == null || osHandlers == null,
         'Pass either os or osHandlers, not both.',
       ),
       _os = os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
       _extensions = extensions,
       _logger = logger,
       _interceptor = interceptor,
       _sandbox = sandbox,
       _descriptionProvider = descriptionProvider {
    if (!sandbox) {
      // Shared mode: create persistent REPL-backed interpreter.
      // ReplPlatform retains all state (variables, functions, classes) natively
      // in the Rust heap across execute() calls — no Dart-side serialization.
      _sharedRepl = MontyRepl();
      _sharedPlatform = ReplPlatform(repl: _sharedRepl!);
      _sharedBridge = PlatformBridge(
        platform: _sharedPlatform!,
        useFutures: false,
        logger: logger,
        interceptor: interceptor,
        runtime: this,
      );
      // OS registration is deferred to the first execute() call via
      // ExtensionCoordinator.attachTo(bridge, baseOs: _os).

      _sharedRegistry = ExtensionCoordinator();
      if (extensions != null) {
        extensions.forEach(_sharedRegistry!.register);
      }
    } else {
      // Sandbox mode: build a schema bridge once for introspection.
      _schemaBridge = _buildBridge();
    }
  }

  final OsCallHandler? _os;
  final List<MontyExtension>? _extensions;
  final BridgeLogger? _logger;
  final MontyInterceptor? _interceptor;
  final bool _sandbox;
  final DescriptionProvider? _descriptionProvider;

  // Shared mode state.
  MontyRepl? _sharedRepl;
  MontyPlatform? _sharedPlatform;
  PlatformBridge? _sharedBridge;
  ExtensionCoordinator? _sharedRegistry;
  bool _sharedAttached = false;

  // Sandbox mode schema bridge (no platform, just for introspection).
  PlatformBridge? _schemaBridge;

  bool _disposed = false;
  int _nextExecutionId = 0;
  final List<HostFunction> _extraFunctions = [];
  final StreamController<BridgeEvent> _eventsController =
      StreamController<BridgeEvent>.broadcast();

  /// All registered tool schemas — feed these to an LLM as tool definitions.
  List<HostFunctionSchema> get schemas =>
      (_sharedBridge ?? _schemaBridge)?.schemas ?? [];

  /// Schemas for functions that declare [FunctionSurface.llm].
  ///
  /// Feed these to an LLM as tool definitions.
  List<HostFunctionSchema> get exposedSchemas =>
      (_sharedBridge ?? _schemaBridge)?.exposedSchemas ?? [];

  /// Broadcast stream of all [BridgeEvent]s emitted across every execution,
  /// including child executions spawned via extensions such as
  /// `SandboxExtension`.
  ///
  /// Child-plugin events arrive wrapped in [BridgeChildEvent] with
  /// `childHandle` set to the plugin's local handle (e.g. a sandbox child
  /// id). Observers that need all executions (e.g. `ExecutionTracker`) can
  /// attach once at construction and receive events from every `execute()`
  /// call on this runtime — and every child — without re-attaching per call.
  Stream<BridgeEvent> get events => _eventsController.stream;

  @override
  void emitChildEvent(String childHandle, BridgeEvent event) {
    if (_disposed) return;
    if (_eventsController.isClosed) return;
    _eventsController.add(
      BridgeChildEvent(childHandle: childHandle, inner: event),
    );
  }

  /// Whether this session creates a fresh interpreter per `execute()`.
  bool get isSandboxMode => _sandbox;

  /// The shared [ExtensionCoordinator] for this runtime.
  ///
  /// Non-null in shared mode (the default). Returns the same instance across
  /// all `execute()` calls until [clearState] is called, at which point a new
  /// coordinator is created and this getter returns that new instance.
  ///
  /// Always `null` in sandbox mode — each `execute()` call owns its own
  /// transient coordinator that is disposed when the call finishes.
  ///
  /// Consumers (e.g. `MontyRuntimeExtension`) use this to subscribe to inner
  /// extension state via [ExtensionCoordinator.statefulObservations].
  ExtensionCoordinator? get coordinator => _sharedRegistry;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    final fn = _applyDescription(function);
    if (_sharedBridge != null) {
      _sharedBridge!.register(fn);
    }
    _extraFunctions.add(fn);
  }

  /// Executes Python [code] with state persistence and full tool access.
  ///
  /// Returns an [ExecutionHandle] with the events stream, terminal result
  /// future, and a cooperative cancel hook. Variables defined in [code]
  /// persist across subsequent `execute()` calls (shared mode) or are
  /// discarded after each call (sandbox mode). All registered host
  /// functions and extensions are callable from Python.
  ///
  /// Wait for completion with `handle.result`; observe events with
  /// `handle.events.listen(...)` (subscribe synchronously after obtaining
  /// the handle to see the full sequence).
  ///
  /// Passing [os] overrides the runtime's session OS handler for this one
  /// call — useful for swapping in a scoped filesystem / env for a single
  /// execution without mutating session state. Children spawned during the
  /// call inherit the override via `HostContext.os` and `spawnChild`.
  @override
  ExecutionHandle execute(
    String code, {
    OsCallHandler? os,
    Map<String, Object?>? inputs,
  }) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    final effective = inputs != null && inputs.isNotEmpty
        ? '${inputsToCode(inputs)}\n$code'
        : code;

    if (_sandbox) {
      return _executeSandboxed(effective, osOverride: os);
    }

    return _executeShared(effective, osOverride: os);
  }

  /// Invokes a registered host function directly from Dart — useful for
  /// exercising tools without routing through Python.
  ///
  /// Routes through the same [MontyInterceptor] chain as Python-originated
  /// tool calls, so access policies, logging middleware, and rate limiters
  /// apply uniformly regardless of call origin. Infra functions still bypass
  /// the interceptor.
  ///
  /// Shared mode only — in sandbox mode each execution owns its own bridge
  /// and there is no persistent registry to invoke against. Callers that
  /// need Dart-side invocation should use shared mode.
  ///
  /// When [onEvent] is provided, any [BridgeEvent] the handler emits is
  /// delivered to the callback before the returned future completes. When
  /// omitted, emissions are dropped (direct-Dart invocations do not route
  /// through [events]).
  ///
  /// Throws:
  /// - [StateError] if the runtime is disposed.
  /// - [UnsupportedError] if called on a sandbox-mode runtime.
  /// - [ArgumentError] if [name] is not registered.
  Future<Object?> invoke(
    String name,
    Map<String, Object?> args, {
    void Function(BridgeEvent)? onEvent,
  }) async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (_sandbox) {
      throw UnsupportedError(
        'MontyRuntime.invoke() is only available in shared mode. '
        'In sandbox mode, call host functions from Python via execute().',
      );
    }
    if (!_sharedAttached) {
      await _sharedRegistry!.attachTo(
        _sharedBridge!,
        baseOs: _os,
        descriptionProvider: _descriptionProvider,
      );
      _sharedAttached = true;
    }

    return _sharedBridge!.invokeHostFunction(name, args, onEvent: onEvent);
  }

  /// Clears all persisted Python state.
  ///
  /// In shared mode, recreates the full interpreter stack ([MontyRepl],
  /// [ReplPlatform], [PlatformBridge], and [ExtensionCoordinator]) so the
  /// next `execute()` call starts with empty Python globals. Plugins are
  /// re-attached on the next `execute()` call.
  ///
  /// In sandbox mode, each call already uses a fresh interpreter — this is
  /// a no-op.
  void clearState() {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (!_sandbox && _sharedBridge != null) {
      final oldPlatform = _sharedPlatform;
      final oldRegistry = _sharedRegistry;

      _sharedRepl = MontyRepl();
      _sharedPlatform = ReplPlatform(repl: _sharedRepl!);
      _sharedBridge = PlatformBridge(
        platform: _sharedPlatform!,
        useFutures: false,
        logger: _logger,
        runtime: this,
      );
      _extraFunctions.forEach(_sharedBridge!.register);

      _sharedRegistry = ExtensionCoordinator();
      if (_extensions != null) {
        _extensions.forEach(_sharedRegistry!.register);
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
    await _eventsController.close();
  }

  // ---------------------------------------------------------------------------
  // Shared mode execution
  // ---------------------------------------------------------------------------

  ExecutionHandle _executeShared(String code, {OsCallHandler? osOverride}) {
    final executionId = 'exec-${_nextExecutionId++}';
    final resultCompleter = Completer<MontyResult>();
    final controller = StreamController<BridgeEvent>.broadcast();
    final cancelToken = CancelToken();

    unawaited(
      Future.microtask(() async {
        OsCallHandler? priorOs;
        final overrideActive = osOverride != null;
        try {
          if (!_sharedAttached) {
            await _sharedRegistry!.attachTo(
              _sharedBridge!,
              baseOs: _os,
              descriptionProvider: _descriptionProvider,
            );
            _sharedAttached = true;
          }
          if (overrideActive) {
            priorOs = _sharedBridge!.currentOsHandler;
            _sharedBridge!.setOsHandler(osOverride);
          }
          final collected = <BridgeEvent>[];
          await for (final event in _sharedBridge!.execute(code)) {
            collected.add(event);
            if (!_eventsController.isClosed) _eventsController.add(event);
            if (!controller.isClosed) controller.add(event);
          }
          if (!resultCompleter.isCompleted) {
            resultCompleter.complete(extractBridgeResult(collected, 0));
          }
        } on Object catch (e, st) {
          if (!resultCompleter.isCompleted) {
            resultCompleter.completeError(e, st);
          }
        } finally {
          if (overrideActive) _sharedBridge?.setOsHandler(priorOs);
          if (!controller.isClosed) await controller.close();
        }
      }),
    );

    return ExecutionHandle(
      events: controller.stream,
      result: resultCompleter.future,
      executionId: executionId,
      cancel: () async => cancelToken.cancel(),
    );
  }

  // ---------------------------------------------------------------------------
  // Sandbox mode execution
  // ---------------------------------------------------------------------------

  ExecutionHandle _executeSandboxed(String code, {OsCallHandler? osOverride}) {
    final executionId = 'exec-${_nextExecutionId++}';
    final resultCompleter = Completer<MontyResult>();
    final controller = StreamController<BridgeEvent>.broadcast();
    final cancelToken = CancelToken();

    unawaited(
      Future.microtask(() async {
        final repl = MontyRepl();
        final platform = ReplPlatform(repl: repl);
        final b = _buildBridge(platform: platform);

        final registry = ExtensionCoordinator();
        if (_extensions != null) {
          _extensions.forEach(registry.register);
        }
        MontyResult? result;
        Object? error;
        StackTrace? stackTrace;
        try {
          await registry.attachTo(
            b,
            baseOs: osOverride ?? _os,
            descriptionProvider: _descriptionProvider,
          );
          final collected = <BridgeEvent>[];
          await for (final event in b.execute(code)) {
            collected.add(event);
            if (!_eventsController.isClosed) _eventsController.add(event);
            if (!controller.isClosed) controller.add(event);
          }
          result = extractBridgeResult(collected, 0);
        } on Object catch (e, st) {
          error = e;
          stackTrace = st;
        } finally {
          try {
            await registry.disposeAll();
          } on Object catch (e, st) {
            error ??= e;
            stackTrace ??= st;
          }
          b.dispose();
          await platform.dispose();
          if (!controller.isClosed) await controller.close();
          if (!resultCompleter.isCompleted) {
            if (error != null) {
              resultCompleter.completeError(error, stackTrace);
            } else {
              resultCompleter.complete(result!);
            }
          }
        }
      }),
    );

    return ExecutionHandle(
      events: controller.stream,
      result: resultCompleter.future,
      executionId: executionId,
      cancel: () async => cancelToken.cancel(),
    );
  }

  // ---------------------------------------------------------------------------
  // Bridge factory
  // ---------------------------------------------------------------------------

  PlatformBridge _buildBridge({MontyPlatform? platform}) {
    final b = PlatformBridge(
      platform: platform ?? ReplPlatform(repl: MontyRepl()),
      useFutures: false,
      logger: _logger,
      interceptor: _interceptor,
      runtime: this,
    );

    // OS registration is handled by
    // ExtensionCoordinator.attachTo(b, baseOs: _os).

    _extraFunctions.forEach(b.register);

    return b;
  }

  HostFunction _applyDescription(HostFunction fn) {
    if (_descriptionProvider == null) return fn;
    final schema = fn.schema;
    final desc = _descriptionProvider(schema.name);
    if (desc == null) return fn;

    return HostFunction(
      schema: HostFunctionSchema(
        name: schema.name,
        description: desc,
        params: schema.params,
      ),
      ffiHandler: fn.ffiHandler,
      wasmHandler: fn.wasmHandler,
      isInfra: fn.isInfra,
      surfaces: fn.surfaces,
      childPropagation: fn.childPropagation,
    );
  }
}
