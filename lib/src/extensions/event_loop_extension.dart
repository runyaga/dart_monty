import 'dart:async';

import 'package:dart_monty/src/attach_context.dart';
import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/host_args.dart';
import 'package:dart_monty/src/host_context.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/host_param.dart';
import 'package:dart_monty/src/host_param_type.dart';
import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/platform_bridge.dart';
import 'package:dart_monty/src/stateful_extension.dart';
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

/// Python is paused at `el_recv()`, holding an unresolved [completer].
final class BridgeChannelWaiting extends BridgeChannelState {
  /// Creates a [BridgeChannelWaiting].
  // ignore: prefer-declaring-const-constructor — Completer cannot be const
  BridgeChannelWaiting(this.completer);

  /// The pending completer that will resume Python when fulfilled.
  final Completer<Map<String, Object?>> completer;
}

/// Script completed (normally or with error).
final class BridgeChannelCompleted extends BridgeChannelState {
  /// Creates a [BridgeChannelCompleted].
  const BridgeChannelCompleted();
}

/// Plugin has been disposed.
final class BridgeChannelDisposed extends BridgeChannelState {
  /// Creates a [BridgeChannelDisposed].
  const BridgeChannelDisposed();
}

/// A `MontyExtension` that turns a single `execute` call into a long-running
/// cooperative exchange between Python and Dart.
///
/// ## Pattern
///
/// Normal `execute` is a one-shot call: Python runs to completion and
/// returns one value. [EventLoopExtension] extends this into a multi-round
/// protocol. Python becomes a coroutine — it runs, emits output, suspends,
/// waits for input, and continues — all within one `execute` call. Dart is
/// the scheduler that decides when to resume it.
///
/// Two host functions are registered that Python calls directly:
///
/// - `el_emit(value)` — Python pushes a value to Dart (non-blocking). Dart
///   observes the new value via [lastEmitted] or reacts to changes via
///   [lastEmittedSignal].
///
/// - `el_recv()` — Python blocks until Dart calls [dispatch]. The return
///   value of `el_recv()` is whatever was passed to [dispatch]. If values
///   were queued before Python reached `el_recv()`, the oldest queued value
///   is returned immediately without suspending.
///
/// ## Lifecycle
///
/// ```text
/// idle → executing → waiting → executing → … → completed
///                       ↑              ↓
///                  dispatch(v)    (Python resumes with v)
/// ```
///
/// Only one `el_recv()` can be pending at a time. Values dispatched while
/// Python is executing (not yet at `el_recv()`) are queued and delivered
/// FIFO when Python next calls `el_recv()`.
///
/// ## Usage
///
/// Register through `ExtensionCoordinator` for automatic wiring:
///
/// ```dart
/// final ext = EventLoopExtension();
/// final session = MontyRuntime(extensions: [ext]);
/// session.executeStream(script);
/// ext.dispatch({'action': 'increment'});
/// ```
///
/// This extension registers a stream wrapper in [onAttach] to track execution
/// lifecycle state.
///
/// ## Reactive observation
///
/// Channel state and emitted values are exposed as signals:
///
/// ```dart
/// effect(() {
///   final state = plugin.channelStateSignal.value;
///   if (state is BridgeChannelWaiting) showInputField();
/// });
/// ```
class EventLoopExtension extends MontyExtension
    with StatefulExtension<BridgeChannelState> {
  /// Creates an [EventLoopExtension] initialized at [BridgeChannelIdle].
  EventLoopExtension() {
    setInitialState(const BridgeChannelIdle());
  }

  final Signal<Map<String, Object?>?> _lastEmitted =
      signal<Map<String, Object?>?>(null);
  final _eventQueue = <Map<String, Object?>>[];
  bool _disposed = false;

  @override
  String get namespace => 'el';

  @override
  String? get systemPromptContext =>
      'Cooperative event loop: el_recv() pauses until the host dispatches '
      'an event; el_emit(value) sends a value back to the host.';

  /// Reactive channel state.
  ///
  /// Subscribe via [effect] for reactive state changes:
  /// ```dart
  /// effect(() => print(plugin.channelStateSignal.value));
  /// ```
  /// Use [channelState] for non-reactive reads.
  ReadonlySignal<BridgeChannelState> get channelStateSignal => stateSignal;

  /// Reactive last-emitted value.
  ///
  /// Updates whenever Python calls `el_emit`. Use [lastEmitted] for
  /// non-reactive reads, or subscribe via [effect] to react to each emission.
  ReadonlySignal<Map<String, Object?>?> get lastEmittedSignal => _lastEmitted;

  /// Current channel state.
  BridgeChannelState get channelState => state;

  /// The most recent value passed to `el_emit`, or `null` if none yet.
  Map<String, Object?>? get lastEmitted => _lastEmitted.value;

  /// Whether Python is currently paused at `el_recv()`.
  bool get isWaiting => state is BridgeChannelWaiting;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'el_recv',
        description:
            'Pause execution until an event is dispatched from the host.',
      ),
      handler: _handleRecv,
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
    if (ctx is PlatformBridge) {
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
    if (state is BridgeChannelCompleted) {
      _eventQueue.clear();
    }
    state = const BridgeChannelExecuting();

    return stream.map((event) {
      if (event is BridgeRunFinished || event is BridgeRunError) {
        // Guard on the plain bool, not the signal, to avoid reading a
        // disposed signal when onDispose() races with the stream tail.
        if (!_disposed) {
          final current = state;
          // Clean up orphaned completer when the script finishes while Python
          // is still paused at el_recv() (e.g. script errored mid-execution).
          if (current is BridgeChannelWaiting) {
            current.completer.completeError(
              StateError('Script finished while waiting for event'),
              StackTrace.current,
            );
          }
          state = const BridgeChannelCompleted();
        }
      }

      return event;
    });
  }

  /// Dispatches a value to the Python coroutine.
  ///
  /// If Python is paused at `el_recv()`, it resumes immediately with [event].
  /// Otherwise [event] is queued for the next `el_recv()` call.
  ///
  /// Throws [StateError] if the plugin has been disposed or if the previous
  /// execution has already completed. Call `execute` again before dispatching.
  void dispatch(Map<String, Object?> event) {
    switch (state) {
      case BridgeChannelDisposed():
        throw StateError('Cannot dispatch events on a disposed plugin');
      case BridgeChannelCompleted():
        throw StateError(
          'Cannot dispatch events after execution completed; '
          'start a new execute() first',
        );
      case BridgeChannelWaiting(:final completer):
        logger.trace(
          'Dispatching event (resuming)',
          attributes: {'eventKeys': '${event.keys.toList()}'},
        );
        state = const BridgeChannelExecuting();
        completer.complete(event);
      case BridgeChannelIdle() || BridgeChannelExecuting():
        logger.trace(
          'Dispatching event (queued)',
          attributes: {'eventKeys': '${event.keys.toList()}'},
        );
        _eventQueue.add(event);
    }
  }

  @override
  Future<void> onDispose() async {
    if (_disposed) return;
    _disposed = true;
    final current = state;
    if (current is BridgeChannelWaiting) {
      current.completer.completeError(
        StateError('EventLoopExtension disposed while waiting for event'),
        StackTrace.current,
      );
    }
    _eventQueue.clear();
    state = const BridgeChannelDisposed();
    _lastEmitted.dispose();
    await super.onDispose();
  }

  Future<Object?> _handleRecv(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    // If events are already queued, return the first one immediately.
    if (_eventQueue.isNotEmpty) {
      return _eventQueue.removeAt(0);
    }

    // No events queued — park in waiting state with the live completer.
    final completer = Completer<Map<String, Object?>>();
    state = BridgeChannelWaiting(completer);
    logger.trace('Waiting for event');

    return completer.future;
  }

  Future<Object?> _handleEmit(Map<String, Object?> args, HostContext ctx) {
    final value = args.mapArg('value');
    _lastEmitted.value = value;

    return Future.value();
  }
}
