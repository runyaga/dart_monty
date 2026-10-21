import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Tracks events, result, identity, and cancellation for one execution.
class ExecutionHandle {
  /// Captures one execution's observable lifecycle.
  const ExecutionHandle({
    required this.events,
    required this.result,
    required this.executionId,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  /// Broadcasts events until execution settles without replaying earlier
  /// events.
  final Stream<BridgeEvent> events;

  /// Completes with the final value or the originating failure.
  final Future<MontyValue> result;

  /// Correlates this execution with events and telemetry.
  final String executionId;

  final Future<void> Function() _cancel;

  /// Idempotently signals the execution cancellation token. Handlers decide
  /// how to stop pending work, and the runtime closes the active session.
  Future<void> cancel() => _cancel();
}

/// Signals best-effort cancellation to cooperating host handlers.
class CancelToken {
  /// Creates a new, un-cancelled token.
  CancelToken();

  final Completer<void> _completer = Completer<void>();
  bool _isCancelled = false;

  /// Whether cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Completes `void` when cancellation is requested. Never errors.
  Future<void> get future => _completer.future;

  /// Requests cancellation. Idempotent.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    if (!_completer.isCompleted) _completer.complete();
  }
}
