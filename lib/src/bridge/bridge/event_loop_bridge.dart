import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/os_call/os_handlers.dart';

/// State of the event loop bridge lifecycle.
enum EventLoopState {
  /// Bridge created but no script executing.
  idle,

  /// Python code is actively executing (not waiting for events).
  executing,

  /// Python is paused at `wait_for_event()`.
  waitingForEvent,

  /// Script completed (normally or with error).
  completed,

  /// Bridge has been disposed.
  disposed,
}

/// Callback invoked when Python calls `render_ui`.
typedef RenderUiCallback = void Function(Map<String, dynamic> schema);

/// A [DefaultMontyBridge] subclass for bidirectional Python/Flutter state.
///
/// Registers two host functions:
/// - `wait_for_event` -- pauses Python until [dispatchUiEvent] is called
/// - `render_ui` -- stores a UI schema and invokes [onRenderUi]
///
/// Python holds state in a `while True` loop, calling `wait_for_event()` to
/// pause and `render_ui(schema)` to push UI updates. The host dispatches
/// user interactions via [dispatchUiEvent].
class EventLoopBridge extends DefaultMontyBridge {
  /// Creates an [EventLoopBridge].
  ///
  /// Pass [onRenderUi] to receive schema updates when Python calls
  /// `render_ui`. Pass [platform] and [limits] as with [DefaultMontyBridge].
  EventLoopBridge({
    required super.platform,
    super.limits,
    OsCallHandler? os,
    this.onRenderUi,
  }) : super(useFutures: true) {
    if (os != null) registerOs(os);
    _registerEventLoopFunctions();
  }

  /// Optional callback invoked when Python calls `render_ui`.
  final RenderUiCallback? onRenderUi;

  final _eventQueue = <Map<String, dynamic>>[];
  Completer<Map<String, dynamic>>? _pendingCompleter;
  Map<String, dynamic>? _lastRenderedUi;
  EventLoopState _loopState = EventLoopState.idle;

  final _eventLoopController = StreamController<BridgeEvent>.broadcast();

  /// Current state of the event loop.
  EventLoopState get loopState => _loopState;

  /// The most recent schema passed to `render_ui`, or `null`.
  Map<String, dynamic>? get lastRenderedUi => _lastRenderedUi;

  /// Whether Python is currently paused at `wait_for_event()`.
  bool get isWaitingForEvent => _loopState == EventLoopState.waitingForEvent;

  /// Stream of event-loop lifecycle events.
  ///
  /// Emits [BridgeEventLoopWaiting], [BridgeEventLoopResumed], and
  /// [BridgeUiRendered] as the event loop progresses.
  Stream<BridgeEvent> get eventLoopEvents => _eventLoopController.stream;

  /// Dispatches a UI event to the Python event loop.
  ///
  /// If Python is waiting at `wait_for_event()`, the completer is resolved
  /// immediately. Otherwise the event is queued for the next call.
  ///
  /// Throws [StateError] if the bridge has been disposed.
  void dispatchUiEvent(Map<String, dynamic> event) {
    if (_loopState == EventLoopState.disposed) {
      throw StateError('Cannot dispatch events on a disposed bridge');
    }
    log.trace(
      'Dispatching UI event',
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
          name: 'wait_for_event',
          description: 'Pauses the event loop until a UI event is dispatched.',
        ),
        handler: _handleWaitForEvent,
      ),
    );

    register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'render_ui',
          description: 'Renders a UI schema to the host.',
          params: [
            HostParam(
              name: 'schema',
              type: HostParamType.map,
              description: 'The UI schema to render.',
            ),
          ],
        ),
        handler: _handleRenderUi,
      ),
    );
  }

  Future<Object?> _handleWaitForEvent(Map<String, Object?> args) async {
    // If events are already queued, return the first one immediately.
    if (_eventQueue.isNotEmpty) {
      final event = _eventQueue.removeAt(0);
      _eventLoopController
        ..add(const BridgeEventLoopWaiting())
        ..add(BridgeEventLoopResumed(event: event));

      return event;
    }

    // No events queued — create a completer and wait.
    _loopState = EventLoopState.waitingForEvent;
    log.trace('Waiting for event');
    _eventLoopController.add(const BridgeEventLoopWaiting());

    final completer = Completer<Map<String, dynamic>>();
    _pendingCompleter = completer;

    return completer.future;
  }

  Future<Object?> _handleRenderUi(Map<String, Object?> args) async {
    final schema = args['schema']! as Map<String, dynamic>;
    _lastRenderedUi = schema;
    _eventLoopController.add(BridgeUiRendered(schema: schema));
    onRenderUi?.call(schema);

    return null;
  }
}
