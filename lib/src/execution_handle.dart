import 'dart:async';

import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Handle to an in-flight `MontyRuntime.execute()` call.
///
/// Exposes the full lifecycle of one execution in a single value:
/// - [events]: broadcast stream of this execution's `BridgeEvent`s.
/// - [result]: resolves with the final [MontyResult] (or errors).
/// - [cancel]: requests cooperative cancellation.
/// - [executionId]: correlate per-execution events with telemetry.
///
/// Replaces the pre-Step-8 split API where `execute()` returned
/// `Future<MontyResult>` and `executeStream()` returned
/// `Stream<BridgeEvent>` — callers that needed both had to run the
/// execution twice or reach around the runtime.
class ExecutionHandle {
  /// Creates an [ExecutionHandle].
  const ExecutionHandle({
    required this.events,
    required this.result,
    required this.executionId,
    required Future<void> Function() cancel,
  }) : _cancel = cancel;

  /// Broadcast stream of bridge events emitted during this execution.
  ///
  /// The stream closes when execution finishes (success or error). Late
  /// subscribers may miss events emitted before they attach — subscribe
  /// synchronously after obtaining the handle to see the full sequence.
  final Stream<BridgeEvent> events;

  /// Completes with the final [MontyResult] when the execution finishes,
  /// or an error if the execution failed.
  final Future<MontyResult> result;

  /// Stable identifier for this execution. Used to correlate events and
  /// telemetry across the ownership tree.
  final String executionId;

  final Future<void> Function() _cancel;

  /// Requests cooperative cancellation of the execution. Idempotent.
  ///
  /// Flips the execution's `CancelToken`; cooperating host function
  /// handlers race it against their own long-running work to bail early.
  /// The bridge does not forcibly terminate Python execution.
  Future<void> cancel() => _cancel();
}

/// Cooperative cancellation token handed to host function handlers via
/// `HostContext.cancelToken`.
///
/// Fires [future] (completes `void`) when the owning execution is cancelled.
/// Handlers that do long work can race their own futures against
/// `cancelToken.future` to bail out early:
///
/// ```dart
/// final result = await Future.any([
///   _slowFetch(),
///   ctx.cancelToken.future.then((_) => throw const CancelledException()),
/// ]);
/// ```
///
/// Cancellation is best-effort — the bridge does not forcibly terminate
/// in-flight Python execution. The token simply flips `isCancelled` true
/// and resolves [future] so cooperating handlers can short-circuit.
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
