import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/monty_runtime_ref.dart';
import 'package:meta/meta.dart';

/// Context passed to every [HostFunctionHandler] invocation.
///
/// Gives handlers:
/// - [emit] — push any [BridgeEvent] into the execution stream mid-call
/// - [emitText] — convenience shorthand for [BridgeToolEmit] text output
/// - [executionId] — correlate events across the [BridgeEvent] stream
/// - [runtime] — the owning runtime, for sub-executions (nullable in tests)
@immutable
class HostContext {
  /// Creates a [HostContext].
  const HostContext({
    required this.emit,
    required this.executionId,
    this.runtime,
  });

  /// Emits an arbitrary [BridgeEvent] during a handler invocation.
  ///
  /// Events land in the execution stream between [BridgeToolCallStart] and
  /// [BridgeToolCallResult]. Use [emitText] for the common case of streaming
  /// progress text, or emit any custom event type directly.
  final void Function(BridgeEvent event) emit;

  /// Bridge-assigned call identifier for the current tool invocation.
  ///
  /// Available in [BridgeToolEmit] and other per-call events.
  final String executionId;

  /// The owning runtime that dispatched this tool call.
  ///
  /// `null` in test contexts where no full runtime is wired up. Handlers that
  /// need to drive sub-executions should null-check before calling.
  final MontyRuntimeRef? runtime;

  /// Emits a [BridgeToolEmit] text event — convenience over calling [emit]
  /// directly for the common streaming-progress use case.
  void emitText(String text) =>
      emit(BridgeToolEmit(callId: executionId, text: text));
}
