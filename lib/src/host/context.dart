import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/host/function.dart' show HostFunctionHandler;
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Context passed to every [HostFunctionHandler] invocation.
///
/// Gives handlers:
/// - [emit] — push any [BridgeEvent] into the execution stream mid-call
/// - [emitText] — convenience shorthand for [BridgeFunctionEmit] text output
/// - [executionId] — correlate events across the [BridgeEvent] stream
/// - [cancelToken] — cooperative cancellation signal for long-running work
/// - [os] — the currently-registered OS handler, for handlers that want to
///   call OS primitives directly without routing through Python
/// - [runtime] — the owning runtime, for sub-executions (nullable in tests)
@immutable
class HostContext {
  /// Creates a [HostContext].
  HostContext({
    required this.emit,
    required this.executionId,
    CancelToken? cancelToken,
    this.os,
    this.runtime,
  }) : cancelToken = cancelToken ?? CancelToken();

  /// Emits an arbitrary [BridgeEvent] during a handler invocation.
  ///
  /// Events land in the execution stream between [BridgeFunctionCallStart]
  /// and [BridgeFunctionCallResult]. Use [emitText] for the common case of
  /// streaming progress text, or emit any custom event type directly.
  final void Function(BridgeEvent event) emit;

  /// Bridge-assigned call identifier for the current tool invocation.
  ///
  /// Available in [BridgeFunctionEmit] and other per-call events.
  final String executionId;

  /// Cooperative cancellation signal for this execution.
  ///
  /// Handlers performing long-running work (HTTP, SSE, sub-processes) should
  /// race their own future against [CancelToken.future] to bail early when
  /// the owning `ExecutionHandle.cancel()` is invoked. Defaults to a
  /// standalone, un-cancelled token when the owning runtime does not supply
  /// one (e.g. test contexts).
  final CancelToken cancelToken;

  /// The OS call handler currently registered with the bridge.
  ///
  /// Host function handlers that want to read files, query environment, or
  /// invoke other OS primitives without routing through Python can call this
  /// directly. `null` when no handler is registered (bridges used purely for
  /// pure-Dart host functions).
  final OsCallHandler? os;

  /// The owning runtime that dispatched this tool call.
  ///
  /// `null` in test contexts where no full runtime is wired up. Handlers that
  /// need to drive sub-executions should null-check before calling.
  final MontyRuntimeRef? runtime;

  /// Emits a [BridgeFunctionEmit] text event — convenience over calling [emit]
  /// directly for the common streaming-progress use case.
  void emitText(String text) =>
      emit(BridgeFunctionEmit(callId: executionId, text: text));
}
