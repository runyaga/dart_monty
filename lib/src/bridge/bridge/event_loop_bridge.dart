import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:signals_core/signals_core.dart';

/// State of the event loop channel lifecycle.
///
/// Sealed — use exhaustive pattern matching to handle all states.
/// [BridgeChannelWaiting] carries the live [Completer] so that the state
/// object is the single source of truth: if no waiting state exists, there
/// is no pending completer.
sealed class BridgeChannelState {
  /// Creates a [BridgeChannelState].
  const BridgeChannelState();
}

/// Bridge created but no script executing.
final class BridgeChannelIdle extends BridgeChannelState {
  /// Creates a [BridgeChannelIdle].
  const BridgeChannelIdle();
}

/// Python code is actively executing (not waiting for input).
final class BridgeChannelExecuting extends BridgeChannelState {
  /// Creates a [BridgeChannelExecuting].
  const BridgeChannelExecuting();
}

/// Python is paused at `recv()`, holding an unresolved [completer].
final class BridgeChannelWaiting extends BridgeChannelState {
  /// Creates a [BridgeChannelWaiting].
  BridgeChannelWaiting(this.completer);

  /// The pending completer that will resume Python when fulfilled.
  final Completer<Map<String, dynamic>> completer;
}

/// Script completed (normally or with error).
final class BridgeChannelCompleted extends BridgeChannelState {
  /// Creates a [BridgeChannelCompleted].
  const BridgeChannelCompleted();
}

/// Bridge has been disposed.
final class BridgeChannelDisposed extends BridgeChannelState {
  /// Creates a [BridgeChannelDisposed].
  const BridgeChannelDisposed();
}

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
///   observes the new value via [lastEmitted] or reacts to changes via
///   [lastEmittedSignal].
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
/// ## Reactive observation
///
/// Channel state and emitted values are exposed as signals for reactive UIs:
///
/// ```dart
/// effect(() {
///   final state = bridge.channelStateSignal.value;
///   if (state is BridgeChannelWaiting) showInputField();
/// });
/// ```
///
/// Plain getters ([channelState], [lastEmitted], [isWaiting]) are the
/// primary API. Signal variants ([channelStateSignal], [lastEmittedSignal])
/// opt in to fine-grained reactivity where needed.
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
/// final bridge = EventLoopBridge(platform: platform);
/// bridge.execute(script);
/// bridge.dispatch({'action': 'increment'});
/// ```
class EventLoopBridge extends DefaultMontyBridge {
  /// Creates an [EventLoopBridge].
  EventLoopBridge({
    required super.platform,
    super.limits,
    super.logger,
  }) : super(useFutures: true) {
    channelStateSignal = _channelState;
    lastEmittedSignal = _lastEmitted;
    _registerEventLoopFunctions();
  }

  /// Reactive channel state.
  ///
  /// Subscribe via [effect] for reactive state changes:
  /// ```dart
  /// effect(() => print(bridge.channelStateSignal.value));
  /// ```
  /// Use [channelState] for non-reactive reads.
  late final ReadonlySignal<BridgeChannelState> channelStateSignal;

  /// Reactive last-emitted value.
  ///
  /// Updates whenever Python calls `emit`. Use [lastEmitted] for
  /// non-reactive reads, or subscribe via [effect] to react to each emission.
  late final ReadonlySignal<Map<String, dynamic>?> lastEmittedSignal;

  final Signal<BridgeChannelState> _channelState =
      signal<BridgeChannelState>(const BridgeChannelIdle());
  final Signal<Map<String, dynamic>?> _lastEmitted =
      signal<Map<String, dynamic>?>(null);
  final _eventQueue = <Map<String, dynamic>>[];

  /// Current channel state.
  BridgeChannelState get channelState => _channelState.value;

  /// The most recent value passed to `emit`, or `null` if none yet.
  Map<String, dynamic>? get lastEmitted => _lastEmitted.value;

  /// Whether Python is currently paused at `recv()`.
  bool get isWaiting => _channelState.value is BridgeChannelWaiting;

  /// Dispatches a value to the Python coroutine.
  ///
  /// If Python is paused at `recv()`, it resumes immediately with [event].
  /// Otherwise [event] is queued for the next `recv()` call.
  ///
  /// Throws [StateError] if the bridge has been disposed or if the previous
  /// execution has already completed. Call [execute] again before dispatching.
  void dispatch(Map<String, dynamic> event) {
    switch (_channelState.value) {
      case BridgeChannelDisposed():
        throw StateError('Cannot dispatch events on a disposed bridge');
      case BridgeChannelCompleted():
        // Design note: a completed bridge has no active Python coroutine to
        // deliver to. Silently queueing here creates phantom state that
        // survives into the next execute() — callers would have no idea
        // whether a queued event belongs to the old or new execution.
        throw StateError(
          'Cannot dispatch events on a completed bridge; call execute() first',
        );
      case BridgeChannelWaiting(:final completer):
        log.trace(
          'Dispatching event (resuming)',
          attributes: {'eventKeys': '${event.keys.toList()}'},
        );
        _channelState.value = const BridgeChannelExecuting();
        completer.complete(event);
      case BridgeChannelIdle() || BridgeChannelExecuting():
        log.trace(
          'Dispatching event (queued)',
          attributes: {'eventKeys': '${event.keys.toList()}'},
        );
        _eventQueue.add(event);
    }
  }

  @override
  Stream<BridgeEvent> execute(String code) {
    _channelState.value = const BridgeChannelExecuting();
    final Stream<BridgeEvent> upstream;
    try {
      upstream = super.execute(code);
    } on Object {
      _channelState.value = const BridgeChannelIdle();
      rethrow;
    }

    return upstream.map((event) {
      if (event is BridgeRunFinished || event is BridgeRunError) {
        final state = _channelState.value;
        if (state is! BridgeChannelDisposed) {
          // Clean up orphaned completer when the script finishes while Python
          // is still paused at recv() (e.g. script errored mid-execution).
          if (state is BridgeChannelWaiting) {
            state.completer.completeError(
              StateError('Script finished while waiting for event'),
              StackTrace.current,
            );
          }
          _channelState.value = const BridgeChannelCompleted();
        }
      }
      return event;
    });
  }

  @override
  void dispose() {
    final state = _channelState.value;
    if (state is BridgeChannelWaiting) {
      state.completer.completeError(
        StateError('Bridge disposed while waiting for event'),
        StackTrace.current,
      );
    }
    _eventQueue.clear();
    _channelState.value = const BridgeChannelDisposed();
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
      return _eventQueue.removeAt(0);
    }

    // No events queued — park in waiting state with the live completer.
    final completer = Completer<Map<String, dynamic>>();
    _channelState.value = BridgeChannelWaiting(completer);
    log.trace('Waiting for event');

    return completer.future;
  }

  Future<Object?> _handleEmit(Map<String, Object?> args) {
    final value = args['value']! as Map<String, dynamic>;
    _lastEmitted.value = value;
    return Future.value();
  }
}
