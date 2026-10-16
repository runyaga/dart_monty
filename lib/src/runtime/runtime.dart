import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/extensions/sandbox.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/dispatch.dart' show RuntimeSubExecutor;
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty/src/runtime/runtime_state.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// MontyRuntime
// ---------------------------------------------------------------------------

/// Checks out a session from a runtime's pool, with [limits] when given.
typedef _RuntimeCheckout =
    Future<MontySession> Function({ResourceLimits? limits});

/// The `maxProcesses` of the pool [MontyRuntime.start] starts when it is
/// given none: a root execution, a sub-execution, and the `maxChildren` of
/// the [SandboxExtension] among [extensions] (none without one).
@visibleForTesting
// ignore: unnecessarily-public-code, pool sizing is asserted by runtime tests.
int defaultPoolSize(List<MontyExtension>? extensions) {
  final sandbox = extensions?.whereType<SandboxExtension>().firstOrNull;

  return (sandbox?.maxChildren ?? 0) + 2;
}

/// The shared-mode [ExtensionCoordinator] of [runtime]; `null` in sandbox
/// mode, where each `execute()` owns a transient one. Internal to dm.
@visibleForTesting
// ignore: unnecessarily-public-code, unused-code, integration tests inspect coordinator identity.
ExtensionCoordinator? runtimeCoordinator(MontyRuntime runtime) =>
    runtime._sharedRegistry;

/// Configured per-session limits, for internal child runtime construction.
// ignore: unnecessarily-public-code, internal cross-library access only.
ResourceLimits? runtimeLimits(MontyRuntime runtime) => runtime._limits;

/// Captures the originating execution before child preparation first awaits.
/// Internal library hand-off; deliberately absent from the facade.
// ignore: library_private_types_in_public_api, unnecessarily-public-code, internal hand-off, not exported.
_ChildExecutionContext captureChildContext(
  MontyRuntime runtime,
  HostContext context,
  ResourceLimits? limits,
) => _ChildExecutionContext(runtime, context, limits);

final class _ChildExecutionContext {
  _ChildExecutionContext(this.runtime, this.context, this.limits)
    : generation = runtime._generation,
      origin = runtime._live
          .where((run) => identical(run.token, context.cancelToken))
          .firstOrNull {
    unawaited(_watchOrigin());
  }

  final MontyRuntime runtime;

  final HostContext context;
  final ResourceLimits? limits;
  final int generation;
  final _Execution? origin;
  final CancelToken token = CancelToken();
  final Completer<void> _finished = Completer<void>();
  Future<MontySession> checkout() async {
    if (!isValid) throw StateError('Child origin is no longer live');
    final session = await runtime._checkout(limits: limits);
    if (!isValid) {
      await session.close();
      throw StateError('Child origin ended during checkout');
    }

    return session;
  }

  Future<MontyValue> subExecute(
    String code, {
    Map<String, MontyValue>? inputs,
    CancelToken? cancelToken,
  }) {
    assert(
      cancelToken == null || identical(cancelToken, token),
      'Child sub-execution must use its child token',
    );

    return runtime._subExecute(
      code,
      generation: generation,
      inputs: inputs,
      cancelToken: token,
      limits: limits,
    );
  }

  void emit(String handle, BridgeEvent event) {
    final wrapped = BridgeChildEvent(childHandle: handle, inner: event);
    final run = origin;
    if (run != null && !run.events.isClosed) run.events.add(wrapped);
    runtime.emitChildEvent(handle, event);
  }

  void finish() {
    if (!_finished.isCompleted) _finished.complete();
    token.cancel();
  }

  Future<void> _watchOrigin() async {
    await Future.any([
      context.cancelToken.future,
      runtime._lifetime.future,
      _finished.future,
    ]);
    if (!_finished.isCompleted) token.cancel();
  }

  bool get isValid =>
      !runtime._disposed &&
      generation == runtime._generation &&
      !context.cancelToken.isCancelled &&
      !token.isCancelled;
}

/// Starts a [MontyRuntime] whose sessions come from [checkout] instead of a
/// pool; [closePool] runs once when the runtime is disposed.
///
/// The seam for tests that script sessions (core's `FakeMontySession`).
/// The other parameters are [MontyRuntime.start]'s.
@visibleForTesting
// ignore: unnecessarily-public-code, unused-code, number-of-parameters, test seam mirrors MontyRuntime.start options.
Future<MontyRuntime> startRuntimeWith({
  required Future<MontySession> Function({ResourceLimits? limits}) checkout,
  Future<void> Function()? closePool,
  OsHandler? os,
  Map<String, OsHandler>? osHandlers,
  List<MontyExtension>? extensions,
  BridgeLogger? logger,
  bool sandbox = false,
  ResourceLimits? limits,
  // ignore: avoid-redundant-async, the assert must fail the Future, not throw.
}) async {
  assert(
    os == null || osHandlers == null,
    'Pass either os or osHandlers, not both.',
  );

  return MontyRuntime._start(
    MontyRuntime._(
      checkout: checkout,
      closePool: closePool,
      os: os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
      extensions: extensions,
      logger: logger,
      sandbox: sandbox,
      limits: limits,
    ),
  );
}

/// High-level agent session — stateful Python execution with tools and
/// extensions.
///
/// Combines `MontyBridge`, `ExtensionCoordinator`, and OS providers into a
/// single API, on sessions checked out of a [Monty] pool.
///
/// Two execution modes:
///
/// **Shared interpreter** (default): one session across all `execute()`
/// calls. Variables, functions, classes, and modules defined in one call are
/// available in every subsequent call.
///
/// **Fresh sandbox** (`sandbox: true`): each `execute()` runs on its own
/// session, closed after it. State does not persist between calls.
///
/// ```dart
/// final pool = await Monty.start(workerLocation: workerPath);
/// final runtime = await MontyRuntime.start(
///   pool: pool,
///   os: OSAccess().call,
/// );
/// await runtime.execute('x = 42').result;
/// final value = await runtime.execute('x + 1').result; // MontyInt(43)
/// ```
class MontyRuntime implements MontyRuntimeRef {
  MontyRuntime._({
    required _RuntimeCheckout checkout,
    required Future<void> Function()? closePool,
    required OsHandler? os,
    required List<MontyExtension>? extensions,
    required BridgeLogger? logger,
    required bool sandbox,
    required ResourceLimits? limits,
  }) : _checkout = checkout,
       _closePool = closePool,
       _os = os,
       _extensions = extensions,
       _logger = logger,
       _sandbox = sandbox,
       _limits = limits;

  /// How long a checkout from the runtime's default pool waits for a free
  /// worker before it fails with [TimeoutException].
  static const Duration defaultCheckoutTimeout = Duration(seconds: 30);

  final _RuntimeCheckout _checkout;
  final Future<void> Function()? _closePool;
  final OsHandler? _os;
  final List<MontyExtension>? _extensions;
  final BridgeLogger? _logger;
  final bool _sandbox;
  final ResourceLimits? _limits;

  // Shared mode: the held session, its bridge and the coordinator.
  SessionBridge? _sharedBridge;
  ExtensionCoordinator? _sharedRegistry;
  // Shared mode: the attachment of the extensions, once started; every
  // first use awaits the same one.
  Future<void>? _sharedAttach;

  // Shared mode: the clearState in progress; the next one waits for it.
  Future<void>? _clearing;

  // Shared mode: a cancel, a crash or a limit closed the held session; the
  // next execution checks out a fresh one.
  bool _sharedStale = false;

  // Shared mode: the execution in progress, which holds the bridge.
  Object? _sharedRun;

  bool _disposed = false;
  Future<void>? _disposal;
  final CancelToken _lifetime = CancelToken();
  int _nextExecutionId = 0;

  // The executions not yet settled; dispose closes their sessions.
  final Set<_Execution> _live = {};
  // The sessions of the sub-executions in progress; dispose and clearState
  // close them.
  final Set<MontySession> _subSessions = {};
  // Counts clearState calls; a sub-execution's checkout that arrives after
  // one is closed unfed.
  int _generation = 0;
  final List<HostFunction> _extraFunctions = [];
  // ignore: dispose-class-fields, closed by the joined _dispose future.
  final StreamController<BridgeEvent> _eventsController =
      StreamController<BridgeEvent>.broadcast();

  /// Starts an agent session.
  ///
  /// The runtime's sessions come from [pool], which the caller sizes and
  /// closes. Without one the runtime starts its own pool, with room for a
  /// root execution, a sub-execution and the `maxChildren` of a
  /// [SandboxExtension] in [extensions], and a [defaultCheckoutTimeout];
  /// [dispose] closes it. That pool finds the worker by core's own
  /// discovery, which throws [StateError] when it finds none.
  ///
  /// An injected pool must have a finite `checkoutTimeout` for bounded
  /// child, sub-execution and transfer acquisition. No timeout is inferred.
  ///
  /// When [sandbox] is false (default), the runtime checks out one session
  /// before the future completes and runs every `execute()` on it. When
  /// [sandbox] is true, each `execute()` call checks out its own session and
  /// closes it afterwards; state does not persist between calls.
  ///
  /// [os] is the OS handler of every feed; [osHandlers] is composed into
  /// one. Pass at most one of them. Extensions attach at the first
  /// `execute()` or [invoke], not here.
  ///
  /// [limits] are the resource limits of the sessions the runtime runs
  /// `execute()` on: the held session in shared mode (and each one that
  /// replaces it), each execution's session in sandbox mode. A
  /// sub-execution inherits the same configured limits. Null keeps
  /// upstream's defaults.
  ///
  /// In shared mode a feed that ends the held session replaces it: a
  /// [MontyCrashedError] (the worker died or was killed), or an uncaught
  /// `MemoryError` or `TimeoutError`, which a memory or time limit raises
  /// and after which upstream says to discard the session. The type decides,
  /// not what raised it: the code's own uncaught `raise TimeoutError()`
  /// replaces the session too. The session is closed, and the next
  /// `execute()` checks out a fresh one, with empty globals; the extensions
  /// stay attached, and it is not a [clearState].
  // ignore: number-of-parameters, the public options of a runtime.
  static Future<MontyRuntime> start({
    Monty? pool,
    OsHandler? os,
    Map<String, OsHandler>? osHandlers,
    List<MontyExtension>? extensions,
    BridgeLogger? logger,
    bool sandbox = false,
    ResourceLimits? limits,
  }) async {
    assert(
      os == null || osHandlers == null,
      'Pass either os or osHandlers, not both.',
    );
    final owned = pool == null;
    final monty =
        pool ??
        await Monty.start(
          maxProcesses: defaultPoolSize(extensions),
          checkoutTimeout: defaultCheckoutTimeout,
        );

    try {
      return await _start(
        MontyRuntime._(
          checkout: monty.checkout,
          closePool: owned ? monty.close : null,
          os: os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
          extensions: extensions,
          logger: logger,
          sandbox: sandbox,
          limits: limits,
        ),
      );
    } on Object {
      if (owned) await monty.close();
      rethrow;
    }
  }

  /// All registered tool schemas — feed these to an LLM as tool definitions.
  ///
  /// In shared mode, the functions registered on the shared bridge, the
  /// extensions' included once they are attached. In sandbox mode each
  /// execution builds its own bridge, so there is no registry to read: the
  /// list is the one fixed at construction, empty, and [register] does not
  /// change it.
  @override
  List<HostFunctionSchema> get schemas => _sharedBridge?.schemas ?? const [];

  /// Broadcast stream of all [BridgeEvent]s emitted across every execution,
  /// including child executions spawned via extensions such as
  /// `SandboxExtension`.
  ///
  /// Child-plugin events arrive wrapped in [BridgeChildEvent] with
  /// `childHandle` set to the plugin's local handle (e.g. a sandbox child
  /// id).
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

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    validateDefaults(function.schema);
    _sharedBridge?.register(function);
    _extraFunctions.add(function);
  }

  /// Executes Python [code] with state persistence and full tool access.
  ///
  /// Returns an [ExecutionHandle] at once, with an `executionId` of the form
  /// `exec-<n>` (`n` counting from 0 per runtime), the execution's events,
  /// its result and a cancel hook. The code runs as one feed: on the held
  /// session in shared mode, on a session checked out for this call in
  /// sandbox mode.
  ///
  /// [inputs] are bound as Python globals by the feed, each converted with
  /// [MontyValue.fromDart]; a value it refuses is an [ArgumentError], thrown
  /// here before a handle exists. Passing [os] replaces the runtime's OS
  /// handler for this one execution: it is the feed's `os` handler, and the
  /// `os` of the execution's host-function contexts.
  ///
  /// The result completes with the feed's [MontyValue], or fails with its
  /// [MontyError]; besides that [ArgumentError], only a disposed runtime's
  /// [StateError] is thrown from here. In shared mode a second `execute`
  /// while one runs runs nothing and fails its result with
  /// `StateError('Bridge is already executing')`.
  @override
  ExecutionHandle execute(
    String code, {
    OsHandler? os,
    Map<String, Object?>? inputs,
  }) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    final values = _inputValues(inputs);
    final run = _Execution('exec-${_nextExecutionId++}');
    _live.add(run);

    if (_sandbox) {
      unawaited(_settle(run, () => _runSandboxed(run, code, os, values)));
    } else if (_sharedRun != null) {
      unawaited(
        _settle(run, () async {
          throw StateError('Bridge is already executing');
        }),
      );
    } else {
      _sharedRun = run;
      unawaited(_settle(run, () => _runShared(run, code, os, values)));
    }

    return ExecutionHandle(
      events: run.events.stream,
      result: run.result.future,
      executionId: run.id,
      cancel: () => _cancel(run),
    );
  }

  /// Invokes a registered host function directly from Dart — useful for
  /// exercising tools without routing through Python. No Python runs.
  ///
  /// Attaches the extensions first if no execution has. [args] are
  /// validated against the function's schema.
  ///
  /// Throws:
  /// - [StateError] if the runtime is disposed.
  /// - [UnsupportedError] if called on a sandbox-mode runtime.
  /// - [ArgumentError] if [name] is not registered.
  Future<MontyValue> invoke(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  }) async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (_sandbox) {
      throw UnsupportedError(
        'MontyRuntime.invoke() is only available in shared mode. '
        'In sandbox mode, call host functions from Python via execute().',
      );
    }
    final bridge = await _attachShared();

    return bridge.invokeHostFunction(name, args, onEvent: onEvent);
  }

  /// Clears all persisted Python state: disposes the extensions, closes the
  /// held session and checks out a new one, with a new bridge and
  /// coordinator. The next `execute()` starts with empty globals and
  /// attaches the extensions again. A no-op in sandbox mode.
  Future<void> clearState() async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (_sandbox) return;

    final next = _clear(_clearing);
    _clearing = next;
    try {
      await next;
    } finally {
      if (identical(_clearing, next)) _clearing = null;
    }
  }

  /// Releases all resources: closes the session of every execution still
  /// running (its result fails as for a cancel), disposes the extensions,
  /// closes the held session, closes the pool when the runtime started it
  /// (a caller's pool stays open), and closes [events]. Idempotent.
  ///
  /// An extension whose `onDispose` throws makes `dispose` throw that error
  /// after the rest is released.
  Future<void> dispose() {
    final pending = _disposal;
    if (pending != null) return pending;
    if (_disposed) return Future.value();

    return _disposal = _dispose();
  }

  Future<void> _dispose() async {
    _disposed = true;
    _lifetime.cancel();
    final cleanup = _DisposalCleanup();
    for (final run in [..._live]) {
      run
        ..stop()
        ..token.cancel();
      await cleanup.closeSession(run.session);
    }
    for (final session in [..._subSessions]) {
      _subSessions.remove(session);
      await cleanup.closeSession(session);
    }
    final bridge = _sharedBridge;
    await cleanup.attempt(_attachSettled);
    await cleanup.attempt(() => _sharedRegistry?.disposeAll());
    await cleanup.attempt(() => bridge?.dispose());
    await cleanup.closeSession(bridge?.session);
    await cleanup.attempt(() => _closePool?.call());
    await cleanup.attempt(_eventsController.close);
    // Concurrent callers join cleanup; later calls retain the no-op contract.
    _disposal = null;
    cleanup.throwIfFailed();
  }

  // ---------------------------------------------------------------------------
  // Executions
  // ---------------------------------------------------------------------------

  /// Runs [code] on a second session checked out of the pool, with
  /// the runtime's configured limits, [inputs] bound as globals by the feed,
  /// no OS handler
  /// and no host functions; the session is closed afterwards. Every
  /// `HostContext.subExecute` of this runtime's bridges, with
  /// [cancelToken] the calling execution's and [generation] the
  /// [clearState] count when the calling bridge was built.
  ///
  /// Completes with the feed's [MontyValue]; fails with its [MontyError],
  /// or with the checkout's error (a pool's `checkoutTimeout` included).
  /// [dispose], [clearState] and a cancel of [cancelToken] close a running
  /// sub-execution's session, so its feed fails; a checkout that arrives
  /// after one of them is closed unfed, and this fails with [StateError].
  Future<MontyValue> _subExecute(
    String code, {
    required int generation,
    required ResourceLimits? limits,
    required Map<String, MontyValue>? inputs,
    required CancelToken? cancelToken,
  }) async {
    if (_subExecutionStopReason(generation, cancelToken) case final reason?) {
      throw StateError(reason);
    }
    final session = await _checkout(limits: limits);
    if (_subExecutionStopReason(generation, cancelToken) case final reason?) {
      await session.close();
      throw StateError(reason);
    }
    _subSessions.add(session);
    Future<void> closeOnCancel(CancelToken token) async {
      await token.future;
      if (_subSessions.remove(session)) await session.close();
    }

    if (cancelToken != null) unawaited(closeOnCancel(cancelToken));
    try {
      return await session.feedRun(code, inputs: inputs);
    } finally {
      if (_subSessions.remove(session)) await session.close();
    }
  }

  String? _subExecutionStopReason(int generation, CancelToken? cancelToken) {
    if (_disposed) return 'MontyRuntime has been disposed';
    if (cancelToken?.isCancelled ?? false) {
      return 'The execution was cancelled';
    }
    if (generation != _generation) return 'The runtime state was cleared';

    return null;
  }

  /// The sub-executor of a bridge built now: its sub-executions stop at the
  /// next [clearState], even one that starts after it.
  RuntimeSubExecutor _subExecutor() {
    final generation = _generation;

    return (code, {inputs, cancelToken}) => _subExecute(
      code,
      inputs: inputs,
      cancelToken: cancelToken,
      generation: generation,
      limits: _limits,
    );
  }

  /// Closes the session of every sub-execution in progress.
  Future<void> _closeSubSessions() async {
    for (final session in [..._subSessions]) {
      _subSessions.remove(session);
      await session.close();
    }
  }

  /// Runs [body] for [run], completing its result with the value or the
  /// error, then closing its event stream.
  Future<void> _settle(
    _Execution run,
    Future<MontyValue> Function() body,
  ) async {
    MontyValue? value;
    Object? error;
    StackTrace? stackTrace;
    try {
      value = await body();
    } on Object catch (e, st) {
      error = e;
      stackTrace = st;
      run.token.cancel();
    } finally {
      run
        ..session = null
        ..finished = true;
      _live.remove(run);
      // Result and event listeners may immediately execute again. Release
      // only this run's slot before either completion becomes observable.
      if (identical(_sharedRun, run)) _sharedRun = null;
    }
    if (error != null) {
      run.result.completeError(error, stackTrace);
    } else {
      run.result.complete(value);
    }
    // Not awaited: a paused listener holds close() until it resumes.
    unawaited(run.events.close());
  }

  /// Cancels [run]: flips its token and, while its feed is running, closes
  /// its session. Does nothing more once the execution has finished.
  Future<void> _cancel(_Execution run) async {
    run.token.cancel();
    if (run.finished || run.cancelled) return;
    run.stop();
    final session = run.session;
    if (session != null) await _closeBusy(run, session);
  }

  /// Closes [session], [run]'s busy session; in shared mode the next
  /// execution then checks out a fresh one.
  Future<void> _closeBusy(_Execution run, MontySession session) {
    if (!_sandbox && identical(session, _sharedBridge?.session)) {
      _sharedStale = true;
    }

    return session.close();
  }

  /// Marks [session] as [run]'s busy session; one cancelled before it got
  /// there is closed at once, so its feed fails.
  Future<void> _hold(_Execution run, MontySession session) async {
    run.session = session;
    if (run.cancelled) await _closeBusy(run, session);
  }

  Future<MontyValue> _runShared(
    _Execution run,
    String code,
    OsHandler? os,
    Map<String, MontyValue>? values,
  ) async {
    // A clearState in progress brings its own session: no re-checkout.
    await _clearingDone(run);
    if (_sharedStale) {
      final fresh = await _checkoutFor(run, _checkoutLive);
      // ignore: no-equal-nested-conditions, the await above may change it.
      if (_sharedStale && _clearing == null) {
        _sharedBridge!.session = fresh;
        _sharedStale = false;
      } else {
        // A clearState replaced the session meanwhile.
        await fresh.close();
      }
    }
    final bridge = await _attachShared(run);
    final session = bridge.session;
    await _hold(run, session);

    try {
      return await _drive(
        run,
        bridge.executeWith(
          code,
          inputs: values,
          os: os,
          cancelToken: run.token,
        ),
      );
    } on MontyError catch (e) {
      if (_endsSession(e)) await _retire(session);
      rethrow;
    }
  }

  /// Closes [session] when it is still the held one, so the next execution
  /// checks out a fresh one; the bridge, its extensions and the clearState
  /// count stay.
  Future<void> _retire(MontySession session) async {
    if (!identical(session, _sharedBridge?.session)) return;
    _sharedStale = true;
    await session.close();
  }

  Future<MontyValue> _runSandboxed(
    _Execution run,
    String code,
    OsHandler? os,
    Map<String, MontyValue>? values,
  ) async {
    final session = await _checkoutFor(run, _checkoutRoot);
    await _hold(run, session);
    final bridge = SessionBridge(
      session: session,
      logger: _logger,
      runtime: this,
      subExecute: _subExecutor(),
    );
    _extraFunctions.forEach(bridge.register);
    final registry = ExtensionCoordinator();
    Object? error;
    StackTrace? stackTrace;
    MontyValue? value;
    try {
      _extensions?.forEach(registry.register);
      await registry.attachTo(bridge, baseOs: os ?? _os);
      value = await _drive(
        run,
        bridge.executeWith(code, inputs: values, cancelToken: run.token),
      );
    } on Object catch (e, st) {
      error = e;
      stackTrace = st;
      run.token.cancel();
    } finally {
      run.session = null;
      try {
        await registry.disposeAll();
      } on Object catch (e, st) {
        error ??= e;
        stackTrace ??= st;
      }
      bridge.dispose();
      await session.close();
    }
    if (error != null) Error.throwWithStackTrace(error, stackTrace!);

    return value!;
  }

  /// Initializes [runtime]; a shared-mode one checks out its
  /// session first.
  static Future<MontyRuntime> _start(MontyRuntime runtime) async {
    if (!runtime._sandbox) await runtime._openShared();

    return runtime;
  }

  /// Checks out the held session and builds its bridge and coordinator.
  Future<void> _openShared() async {
    // Registration validates the extensions before a worker is taken.
    final registry = ExtensionCoordinator();
    _extensions?.forEach(registry.register);
    final session = await _checkoutLive();
    final bridge = SessionBridge(
      session: session,
      logger: _logger,
      runtime: this,
      subExecute: _subExecutor(),
    );
    _extraFunctions.forEach(bridge.register);
    _sharedBridge = bridge;
    _sharedRegistry = registry;
    _sharedAttach = null;
    _sharedStale = false;
  }

  /// A checkout of a root session, with the runtime's limits.
  Future<MontySession> _checkoutRoot() => _checkout(limits: _limits);

  /// A checkout for the shared mode; one that completes after [dispose] is
  /// closed, and throws [StateError].
  Future<MontySession> _checkoutLive() async {
    final session = await _checkoutRoot();
    if (_disposed) {
      await session.close();
      throw StateError('MontyRuntime has been disposed');
    }

    return session;
  }

  /// One [clearState], after [previous] has ended either way.
  Future<void> _clear(Future<void>? previous) async {
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // The earlier call reports its own failure.
      }
    }
    if (_disposed) throw StateError('MontyRuntime has been disposed');

    _generation++;
    await _closeSubSessions();
    final bridge = _sharedBridge!;
    final registry = _sharedRegistry!;
    try {
      await _attachSettled();
      await registry.disposeAll();
    } finally {
      bridge.dispose();
      await bridge.session.close();
      await _openShared();
    }
  }

  /// [checkout]'s session for [run]. When [run] is stopped first, this
  /// throws at once, and the session is closed when it arrives: a waiting
  /// checkout cannot be withdrawn.
  Future<MontySession> _checkoutFor(
    _Execution run,
    Future<MontySession> Function() checkout,
  ) async {
    final pending = checkout();
    final session = await Future.any<MontySession?>([
      pending,
      _whenStopped(run),
    ]);
    if (session == null) {
      unawaited(_closeOnArrival(pending));
      throw StateError('The execution was cancelled before it started');
    }

    return session;
  }

  /// Waits for an attachment in progress, whatever its outcome, so the
  /// extensions are disposed only after they attached.
  Future<void> _attachSettled() async {
    final attach = _sharedAttach;
    if (attach == null) return;
    try {
      await attach;
    } on Object {
      // The execution or invoke that started it reports the failure.
    }
  }

  /// Returns once no clearState is in progress, each one that starts during
  /// the wait included; [run], when given and stopped, ends the wait with
  /// [StateError].
  Future<void> _clearingDone(_Execution? run) async {
    for (var clearing = _clearing; clearing != null; clearing = _clearing) {
      final stopped = await Future.any<bool>([
        _settled(clearing),
        if (run != null) _stoppedTrue(run),
      ]);
      if (stopped) {
        throw StateError('The execution was cancelled before it started');
      }
    }
  }

  /// The shared bridge, with the extensions attached, once no clearState is
  /// in progress; [run], when given, stops the wait.
  Future<SessionBridge> _attachShared([_Execution? run]) async {
    // Re-checked with no await before the attachment starts.
    while (_clearing != null) {
      await _clearingDone(run);
    }
    // From here to the attachment's start nothing awaits, so a clearState
    // that starts later sees the attachment and waits for it.
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    final bridge = _sharedBridge!;
    await (_sharedAttach ??= _sharedRegistry!.attachTo(bridge, baseOs: _os));

    return bridge;
  }

  /// Forwards [stream]'s events to [run] and to [events], and returns the
  /// value its terminal event carries.
  Future<MontyValue> _drive(
    _Execution run,
    Stream<BridgeEvent> stream,
  ) async {
    final collected = <BridgeEvent>[];
    await for (final event in stream) {
      collected.add(event);
      if (!_eventsController.isClosed) _eventsController.add(event);
      run.events.add(event);
    }

    return extractBridgeResult(collected);
  }
}

/// False once [future] has ended, either way.
Future<bool> _settled(Future<void> future) async {
  try {
    await future;
  } on Object {
    // Its own caller reports the failure.
  }

  return false;
}

/// True once [run] is stopped.
Future<bool> _stoppedTrue(_Execution run) async {
  await run.stopped.future;

  return true;
}

/// Null once [run] is stopped.
Future<MontySession?> _whenStopped(_Execution run) async {
  await run.stopped.future;

  return null;
}

/// Closes [pending]'s session when it arrives.
Future<void> _closeOnArrival(Future<MontySession> pending) async {
  final MontySession session;
  try {
    session = await pending;
  } on Object {
    return; // The checkout failed: there is nothing to close.
  }
  await session.close();
}

/// Whether [error] leaves its session unusable: a dead worker, or a memory
/// or time limit, after which upstream says to discard the session.
bool _endsSession(MontyError error) =>
    error is MontyCrashedError ||
    switch (error.exception.excType) {
      'MemoryError' || 'TimeoutError' => true,
      _ => false,
    };

/// [inputs] as the feed's values, each through [MontyValue.fromDart].
Map<String, MontyValue>? _inputValues(Map<String, Object?>? inputs) =>
    inputs?.map((name, value) => MapEntry(name, MontyValue.fromDart(value)));

/// The state of one `MontyRuntime.execute` call.
final class _Execution {
  _Execution(this.id);

  final String id;
  final CancelToken token = CancelToken();
  final StreamController<BridgeEvent> events =
      StreamController<BridgeEvent>.broadcast();
  final Completer<MontyValue> result = Completer<MontyValue>();

  /// The session running the feed, while it runs.
  MontySession? session;
  bool cancelled = false;
  bool finished = false;

  /// Completes when the execution is cancelled or its runtime disposed.
  final Completer<void> stopped = Completer<void>();

  /// Marks the execution cancelled and completes [stopped].
  void stop() {
    cancelled = true;
    if (!stopped.isCompleted) stopped.complete();
  }
}

/// Attempts independent runtime releases while retaining the first failure.
final class _DisposalCleanup {
  final Set<MontySession> _closed = Set.identity();
  Object? _failure;
  StackTrace? _failureStack;

  Future<void> attempt(FutureOr<void> Function() close) async {
    try {
      await close();
    } on Object catch (error, stack) {
      _failure ??= error;
      _failureStack ??= stack;
    }
  }

  Future<void> closeSession(MontySession? session) async {
    if (session != null && _closed.add(session)) {
      await attempt(session.close);
    }
  }

  void throwIfFailed() {
    if (_failure case final error?) {
      Error.throwWithStackTrace(error, _failureStack!);
    }
  }
}
