import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';

/// Represents the internal event-loop channel lifecycle.
sealed class EventLoopState {
  const EventLoopState();
}

/// Bridge created but no script executing.
final class EventLoopIdle extends EventLoopState {
  // The type documentation covers this state.
  // ignore: public_member_api_docs
  const EventLoopIdle();
}

/// Python code is actively executing (not waiting for input).
final class EventLoopExecuting extends EventLoopState {
  // The type documentation covers this state.
  // ignore: public_member_api_docs
  const EventLoopExecuting();
}

/// Python is paused at `el_recv()`, holding an unresolved [completer].
final class EventLoopWaiting extends EventLoopState {
  // The completer makes this state mutable.
  // ignore: prefer-declaring-const-constructor
  // The type documentation covers this state.
  // ignore: public_member_api_docs
  EventLoopWaiting(this.completer);

  /// The pending completer that will resume Python when fulfilled.
  final Completer<MontyDict> completer;
}

/// Script completed (normally or with error).
final class EventLoopCompleted extends EventLoopState {
  // The type documentation covers this state.
  // ignore: public_member_api_docs
  const EventLoopCompleted();
}

/// Plugin has been disposed.
final class EventLoopDisposed extends EventLoopState {
  // The type documentation covers this state.
  // ignore: public_member_api_docs
  const EventLoopDisposed();
}

/// Runs a FIFO cooperative exchange within one Python execution.
class EventLoopExtension extends MontyExtension {
  // The type documentation covers this extension.
  // ignore: public_member_api_docs
  EventLoopExtension();

  final Signal<EventLoopState> _state = signal<EventLoopState>(
    const EventLoopIdle(),
  );
  final Signal<MontyDict?> _lastEmitted = signal<MontyDict?>(null);
  final _eventQueue = <MontyDict>[];
  bool _disposed = false;

  @override
  String get namespace => 'el';

  @override
  String? get systemPromptContext =>
      'Cooperative event loop: el_recv() pauses until the host dispatches '
      'an event; el_emit(value) sends a value back to the host.';

  /// Signals each value emitted by Python.
  ReadonlySignal<MontyDict?> get lastEmittedSignal => _lastEmitted;

  /// The most recent value passed to `el_emit`, or `null` if none yet.
  MontyDict? get lastEmitted => _lastEmitted.value;

  /// Whether Python is currently paused at `el_recv()`.
  bool get isWaiting => _state.value is EventLoopWaiting;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'el_recv',
        description:
            'Pause execution until an event is dispatched from the host.',
      ),
      handler: _handleRecv,
      dispatch: DispatchMode.future,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'el_emit',
        description: 'Emit a value back to the host.',
        params: [
          HostParam(
            name: 'value',
            type: HostParamType.map,
            description: 'The value to emit.',
          ),
        ],
      ),
      handler: _handleEmit,
      dispatch: DispatchMode.future,
    ),
  ];

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      EventLoopExtension();

  @override
  Future<void> onAttach(AttachContext ctx) async {
    await super.onAttach(ctx);
    if (ctx is SessionBridge) {
      ctx.addStreamWrapper(_wrapStream);
    }
  }

  Stream<BridgeEvent> _wrapStream(String code, Stream<BridgeEvent> stream) {
    if (_disposed) {
      throw StateError('Cannot execute on a disposed EventLoopExtension');
    }
    // Clear stale queued events only when re-executing after a completed run.
    // Events dispatched while idle (before the first execute) are intentional
    // pre-dispatch and must not be discarded.
    if (_state.value is EventLoopCompleted) {
      _eventQueue.clear();
    }
    _state.value = const EventLoopExecuting();

    return stream.map((event) {
      if (event is BridgeRunFinished || event is BridgeRunError) {
        // Guard on the plain bool, not the signal, to avoid reading a
        // disposed signal when onDispose() races with the stream tail.
        if (!_disposed) {
          final current = _state.value;
          // Clean up orphaned completer when the script finishes while Python
          // is still paused at el_recv() (e.g. script errored mid-execution).
          if (current is EventLoopWaiting) {
            current.completer.completeError(
              StateError('Script finished while waiting for event'),
              StackTrace.current,
            );
          }
          _state.value = const EventLoopCompleted();
        }
      }

      return event;
    });
  }

  /// Resumes a pending receive or queues the value in FIFO order, and rejects
  /// dispatch after completion or disposal.
  void dispatch(MontyDict event) {
    switch (_state.value) {
      case EventLoopDisposed():
        throw StateError('Cannot dispatch events on a disposed plugin');
      case EventLoopCompleted():
        throw StateError(
          'Cannot dispatch events after execution completed; '
          'start a new execute() first',
        );
      case EventLoopWaiting(:final completer):
        logger.trace(
          'Dispatching event (resuming)',
          attributes: {
            'eventKeys': '${event.pairs.map((pair) => pair.$1).toList()}',
          },
        );
        _state.value = const EventLoopExecuting();
        completer.complete(event);
      case EventLoopIdle() || EventLoopExecuting():
        logger.trace(
          'Dispatching event (queued)',
          attributes: {
            'eventKeys': '${event.pairs.map((pair) => pair.$1).toList()}',
          },
        );
        _eventQueue.add(event);
    }
  }

  @override
  Future<void> onDispose() async {
    if (_disposed) return;
    _disposed = true;
    final current = _state.value;
    if (current is EventLoopWaiting) {
      current.completer.completeError(
        StateError('EventLoopExtension disposed while waiting for event'),
        StackTrace.current,
      );
    }
    _eventQueue.clear();
    _state.value = const EventLoopDisposed();
    _lastEmitted.dispose();
    await super.onDispose();
    _state.dispose();
  }

  /// Supports one pending `el_recv` call. A later call replaces the pending
  /// completer.
  Future<MontyValue> _handleRecv(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
    // If events are already queued, return the first one immediately.
    if (_eventQueue.isNotEmpty) {
      return _eventQueue.removeAt(0);
    }

    // With no queued event, park in a waiting state with the live completer.
    final completer = Completer<MontyDict>();
    _state.value = EventLoopWaiting(completer);
    logger.trace('Waiting for event');

    return completer.future;
  }

  Future<MontyValue> _handleEmit(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) {
    final value = args['value']! as MontyDict;
    _lastEmitted.value = value;

    return Future.value(const MontyNone());
  }
}

/// Exposes internal event-loop state within this package.
extension EventLoopChannel on EventLoopExtension {
  /// Current channel state.
  EventLoopState get channelState => _state.value;

  /// Reactive channel state.
  ReadonlySignal<EventLoopState> get channelStateSignal => _state;
}
