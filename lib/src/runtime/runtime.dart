import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/extensions/sandbox.dart';
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
typedef RuntimeCheckout =
    Future<MontySession> Function({ResourceLimits? limits});

/// The `maxProcesses` of the pool [MontyRuntime.start] starts when it is
/// given none: a root execution, a sub-execution, and the `maxChildren` of
/// the [SandboxExtension] among [extensions] (none without one).
@visibleForTesting
int defaultPoolSize(List<MontyExtension>? extensions) {
  final sandbox = extensions?.whereType<SandboxExtension>().firstOrNull;

  return (sandbox?.maxChildren ?? 0) + 2;
}

/// Starts a [MontyRuntime] whose sessions come from [checkout] instead of a
/// pool; [closePool] runs once when the runtime is disposed.
///
/// The seam for tests that script sessions (core's `FakeMontySession`).
/// The other parameters are [MontyRuntime.start]'s.
@visibleForTesting
Future<MontyRuntime> startRuntimeWith({
  required RuntimeCheckout checkout,
  Future<void> Function()? closePool,
  OsHandler? os,
  Map<String, OsHandler>? osHandlers,
  List<MontyExtension>? extensions,
  BridgeLogger? logger,
  bool sandbox = false,
}) => MontyRuntime._start(
  checkout: checkout,
  closePool: closePool,
  os: os,
  osHandlers: osHandlers,
  extensions: extensions,
  logger: logger,
  sandbox: sandbox,
);

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
///   os: defaultOsHandler(),
/// );
/// await runtime.execute('x = 42').result;
/// final value = await runtime.execute('x + 1').result; // MontyInt(43)
/// ```
class MontyRuntime implements MontyRuntimeRef {
  MontyRuntime._({
    required RuntimeCheckout checkout,
    required Future<void> Function()? closePool,
    required OsHandler? os,
    required List<MontyExtension>? extensions,
    required BridgeLogger? logger,
    required bool sandbox,
  }) : _checkout = checkout,
       _closePool = closePool,
       _os = os,
       _extensions = extensions,
       _logger = logger,
       _sandbox = sandbox;

  /// How long a checkout from the runtime's default pool waits for a free
  /// worker before it fails with [TimeoutException].
  static const Duration defaultCheckoutTimeout = Duration(seconds: 30);

  final RuntimeCheckout _checkout;
  final Future<void> Function()? _closePool;
  final OsHandler? _os;
  final List<MontyExtension>? _extensions;
  final BridgeLogger? _logger;
  final bool _sandbox;

  // Shared mode: the held session, its bridge and the coordinator.
  SessionBridge? _sharedBridge;
  ExtensionCoordinator? _sharedRegistry;
  // Shared mode: the attachment of the extensions, once started; every
  // first use awaits the same one.
  Future<void>? _sharedAttach;

  // Shared mode: the clearState in progress; the next one waits for it.
  Future<void>? _clearing;

  // Shared mode: a cancel closed the held session; the next execution
  // checks out a fresh one.
  bool _sharedStale = false;

  // Shared mode: the execution in progress, which holds the bridge.
  Object? _sharedRun;

  bool _disposed = false;
  int _nextExecutionId = 0;

  // The executions not yet settled; dispose closes their sessions.
  final Set<_Execution> _live = {};
  // The sessions of the sub-executions in progress; dispose closes them.
  final Set<MontySession> _subSessions = {};
  final List<HostFunction> _extraFunctions = [];
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
  /// When [sandbox] is false (default), the runtime checks out one session
  /// before the future completes and runs every `execute()` on it. When
  /// [sandbox] is true, each `execute()` call checks out its own session and
  /// closes it afterwards; state does not persist between calls.
  ///
  /// [os] is the OS handler of every feed; [osHandlers] is composed into
  /// one. Pass at most one of them. Extensions attach at the first
  /// `execute()` or [invoke], not here.
  static Future<MontyRuntime> start({
    Monty? pool,
    OsHandler? os,
    Map<String, OsHandler>? osHandlers,
    List<MontyExtension>? extensions,
    BridgeLogger? logger,
    bool sandbox = false,
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
        checkout: monty.checkout,
        closePool: owned ? monty.close : null,
        os: os,
        osHandlers: osHandlers,
        extensions: extensions,
        logger: logger,
        sandbox: sandbox,
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

  /// The shared [ExtensionCoordinator] for this runtime.
  ///
  /// Non-null in shared mode (the default). Always `null` in sandbox mode —
  /// each `execute()` call owns its own transient coordinator.
  ExtensionCoordinator? get coordinator => _sharedRegistry;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
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
      unawaited(
        _settle(run, () => _runShared(run, code, os, values)).whenComplete(
          () {
            if (identical(_sharedRun, run)) _sharedRun = null;
          },
        ),
      );
    }

    return ExecutionHandle(
      events: run.events.stream,
      result: run.result.future,
      executionId: run.id,
      cancel: () => _cancel(run),
    );
  }

  @override
  Future<MontyValue> subExecute(
    String code, {
    Map<String, Object?>? inputs,
  }) async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    final values = _inputValues(inputs);
    final session = await _checkout();
    if (_disposed) {
      await session.close();
      throw StateError('MontyRuntime has been disposed');
    }
    _subSessions.add(session);
    try {
      return await session.feedRun(code, inputs: values);
    } finally {
      _subSessions.remove(session);
      await session.close();
    }
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
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final run in [..._live]) {
      run
        ..stop()
        ..token.cancel();
      await run.session?.close();
    }
    for (final session in [..._subSessions]) {
      await session.close();
    }
    final bridge = _sharedBridge;
    try {
      await _attachSettled();
      await _sharedRegistry?.disposeAll();
    } finally {
      bridge?.dispose();
      await bridge?.session.close();
      await _closePool?.call();
      await _eventsController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Executions
  // ---------------------------------------------------------------------------

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
    } finally {
      run
        ..session = null
        ..finished = true;
      _live.remove(run);
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
    await _hold(run, bridge.session);

    return _drive(
      run,
      bridge.executeWith(
        code,
        inputs: values,
        os: os,
        cancelToken: run.token,
      ),
    );
  }

  Future<MontyValue> _runSandboxed(
    _Execution run,
    String code,
    OsHandler? os,
    Map<String, MontyValue>? values,
  ) async {
    final session = await _checkoutFor(run, _checkout);
    await _hold(run, session);
    final bridge = SessionBridge(
      session: session,
      logger: _logger,
      runtime: this,
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

  /// Builds the runtime over [checkout]; a shared-mode one checks out its
  /// session first.
  static Future<MontyRuntime> _start({
    required RuntimeCheckout checkout,
    required Future<void> Function()? closePool,
    required OsHandler? os,
    required Map<String, OsHandler>? osHandlers,
    required List<MontyExtension>? extensions,
    required BridgeLogger? logger,
    required bool sandbox,
  }) async {
    assert(
      os == null || osHandlers == null,
      'Pass either os or osHandlers, not both.',
    );
    final runtime = MontyRuntime._(
      checkout: checkout,
      closePool: closePool,
      os: os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
      extensions: extensions,
      logger: logger,
      sandbox: sandbox,
    );
    if (!sandbox) await runtime._openShared();

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
    );
    _extraFunctions.forEach(bridge.register);
    _sharedBridge = bridge;
    _sharedRegistry = registry;
    _sharedAttach = null;
    _sharedStale = false;
  }

  /// A checkout for the shared mode; one that completes after [dispose] is
  /// closed, and throws [StateError].
  Future<MontySession> _checkoutLive() async {
    final session = await _checkout();
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
