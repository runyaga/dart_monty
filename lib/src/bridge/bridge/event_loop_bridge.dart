import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';

/// State of the event loop bridge lifecycle.
enum EventLoopState {
  /// Bridge created but no script executing.
  idle,

  /// Python code is actively executing (not waiting for events).
  executing,

  /// Python is paused at `recv()`.
  waiting,

  /// Script completed (normally or with error).
  completed,

  /// Bridge has been disposed.
  disposed,
}

/// Callback invoked when Python calls `emit`.
typedef EmitCallback = void Function(Map<String, dynamic> value);

/// A [DefaultMontyBridge] that turns a single [execute] call into a
/// long-running cooperative exchange between Python and Dart.
///
/// ## Pattern
///
/// Normal [execute] is a one-shot call: Python runs to completion and
/// returns one value. [EventLoopBridge] extends this into a multi-round
/// protocol. Python becomes a coroutine — it runs, emits output, suspends,
/// waits for input, and continues — all within one [execute] call. Dart is
/// the scheduler that decides when to resume it.
///
/// Two host functions are registered that Python calls directly:
///
/// - `emit(value)` — Python pushes a value to Dart (non-blocking). Dart
///   receives it via [onEmit] and as [BridgeEmitted] on [eventLoopEvents].
///
/// - `recv()` — Python blocks until Dart calls [dispatch]. The return value
///   of `recv()` is whatever was passed to [dispatch]. If values were
///   queued before Python reached `recv()`, the oldest queued value is
///   returned immediately without suspending.
///
/// ## Lifecycle
///
/// ```text
/// idle → executing → waiting → executing → … → completed
///                       ↑              ↓
///                  dispatch(v)    (Python resumes with v)
/// ```
///
/// Only one `recv()` can be pending at a time. Values dispatched while
/// Python is executing (not yet at `recv()`) are queued and delivered
/// FIFO when Python next calls `recv()`.
///
/// ## Example
///
/// ```python
/// # Python — runs inside execute()
/// while True:
///     event = recv()
///     result = process(event)
///     emit(result)
/// ```
///
/// ```dart
/// // Dart
/// final bridge = EventLoopBridge(
///   platform: platform,
///   onEmit: (value) => handleOutput(value),
/// );
/// bridge.execute(script);
/// bridge.dispatch({'action': 'increment'});
/// ```
class EventLoopBridge extends DefaultMontyBridge {
  /// Creates an [EventLoopBridge].
  ///
  /// Pass [onEmit] to receive values when Python calls
  /// `emit`. Pass [platform] and [limits] as with [DefaultMontyBridge].
  EventLoopBridge({
    required super.platform,
    super.limits,
    super.logger,
    this.onEmit,
  }) : super(useFutures: true) {
    _registerEventLoopFunctions();
  }

  /// Optional callback invoked when Python calls `emit`.
  final EmitCallback? onEmit;

  final _eventQueue = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? _pendingCompleter;
  Map<String, dynamic>? _lastEmitted;
  EventLoopState _loopState = EventLoopState.idle;

  final _eventLoopController = StreamController<BridgeEvent>.broadcast();

  /// Current state of the event loop.
  EventLoopState get loopState => _loopState;

  /// The most recent value passed to `emit`, or `null`.
  Map<String, dynamic>? get lastEmitted => _lastEmitted;

  /// Whether Python is currently paused at `recv()`.
  bool get isWaiting => _loopState == EventLoopState.waiting;

  /// Stream of event-loop lifecycle events.
  ///
  /// Emits [BridgeEventLoopWaiting], [BridgeEventLoopResumed], and
  /// `BridgeEmitted` as the event loop progresses.
  Stream<BridgeEvent> get eventLoopEvents => _eventLoopController.stream;

  /// Dispatches a value to the Python coroutine. If Python is paused at
  /// `recv()`, it resumes immediately with [event]. Otherwise [event] is
  /// queued for the next `recv()` call.
  ///
  /// Throws [StateError] if the bridge has been disposed or if the previous
  /// execution has already completed. Call [execute] again before dispatching.
  void dispatch(Map<String, dynamic> event) {
    if (_loopState == EventLoopState.disposed) {
      throw StateError('Cannot dispatch events on a disposed bridge');
    }
    if (_loopState == EventLoopState.completed) {
      // Design note: a completed bridge has no active Python coroutine to
      // deliver to. Silently queueing here creates phantom state that
      // survives into the next execute() — callers would have no idea
      // whether a queued event belongs to the old or new execution.
      // The structural fix is to clear _eventQueue at execute() start, but
      // that would silently discard pre-queued events from legitimate callers.
      // Throwing here is the conservative, discoverable choice.
      throw StateError(
        'Cannot dispatch events on a completed bridge; call execute() first',
      );
    }
    log.trace(
      'Dispatching event',
      attributes: {'eventKeys': '${event.keys.toList()}'},
    );

    final completer = _pendingCompleter;
    if (completer != null && !completer.isCompleted) {
      _pendingCompleter = null;
      _loopState = EventLoopState.executing;
      _eventLoopController.add(BridgeEventLoopResumed(event: event));
      completer.complete(event);
    } else {
      _eventQueue.add(event);
    }
  }

  @override
  Stream<BridgeEvent> execute(String code) {
    _loopState = EventLoopState.executing;
    final Stream<BridgeEvent> upstream;
    try {
      upstream = super.execute(code);
    } on Object {
      _loopState = EventLoopState.idle;
      rethrow;
    }

    return upstream.map((event) {
      // Track completion when the run finishes or errors.
      if (event is BridgeRunFinished || event is BridgeRunError) {
        if (_loopState != EventLoopState.disposed) {
          _loopState = EventLoopState.completed;
        }
        // Clean up any orphaned Completer (e.g. script errored while waiting).
        final completer = _pendingCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            StateError('Script finished while waiting for event'),
            StackTrace.current,
          );
          _pendingCompleter = null;
        }
      }

      return event;
    });
  }

  @override
  void dispose() {
    final completer = _pendingCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        StateError('Bridge disposed while waiting for event'),
        StackTrace.current,
      );
      _pendingCompleter = null;
    }
    _eventQueue.clear();
    _loopState = EventLoopState.disposed;
    unawaited(_eventLoopController.close());
    super.dispose();
  }

  void _registerEventLoopFunctions() {
    register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'recv',
          description:
              'Pauses the coroutine until a value is dispatched from the host.',
        ),
        handler: _handleRecv,
      ),
      category: 'event_loop',
    );

    register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'emit',
          description: 'Emits a value to the host.',
          params: [
            HostParam(
              name: 'value',
              type: HostParamType.map,
              description: 'The value to emit to the host.',
            ),
          ],
        ),
        handler: _handleEmit,
      ),
      category: 'event_loop',
    );
  }

  Future<Object?> _handleRecv(Map<String, Object?> args) async {
    // If events are already queued, return the first one immediately.
    if (_eventQueue.isNotEmpty) {
      final event = _eventQueue.removeAt(0);
      if (_loopState != EventLoopState.disposed) {
        _eventLoopController
          ..add(const BridgeEventLoopWaiting())
          ..add(BridgeEventLoopResumed(event: event));
      }

      return event;
    }

    // No events queued — create a completer and wait.
    _loopState = EventLoopState.waiting;
    log.trace('Waiting for event');
    _eventLoopController.add(const BridgeEventLoopWaiting());

    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleter = completer;

    return completer.future;
  }

  Future<Object?> _handleEmit(Map<String, Object?> args) {
    final value = args['value']! as Map<String, dynamic>;
    _lastEmitted = value;
    if (_loopState != EventLoopState.disposed) {
      // Design note: the bridge may be disposed mid-execution if the host
      // calls dispose() from a concurrent callback. Guarding here prevents
      // adding to a closed StreamController. The structural fix is cooperative
      // cancellation in DefaultMontyBridge._run() so execution stops before
      // host function handlers are invoked after dispose.
      _eventLoopController.add(BridgeEmitted(value: value));
    }
    try {
      onEmit?.call(value);
    } on Object catch (e, st) {
      // Design note: onEmit is a Dart-side side effect. If it throws, the
      // exception must not propagate out of this handler — doing so would
      // cause DefaultMontyBridge to call resumeWithError(), signalling a
      // Python-level failure for what is purely a host callback error.
      // The structural fix is to decouple the callback entirely:
      // either schedule via scheduleMicrotask() so exceptions cannot reach
      // the handler's return path, or remove onEmit and let callers filter
      // eventLoopEvents.whereType<BridgeEmitted>() instead.
      log.error('onEmit callback threw', error: e, stackTrace: st);
    }

    return Future.value();
  }
}
