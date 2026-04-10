import 'package:dart_monty/dart_monty.dart';

/// Protocol-agnostic lifecycle events emitted by a bridge.
///
/// These events describe what happened during Python execution without
/// coupling to any specific event protocol (e.g. ag-ui). Downstream
/// consumers map these to their own protocol types.
sealed class BridgeEvent {
  /// Creates a [BridgeEvent].
  const BridgeEvent();
}

/// Execution started.
class BridgeRunStarted extends BridgeEvent {
  /// Creates a [BridgeRunStarted].
  const BridgeRunStarted({required this.threadId, required this.runId});

  /// Thread identifier.
  final String threadId;

  /// Run identifier.
  final String runId;
}

/// Execution completed successfully.
class BridgeRunFinished extends BridgeEvent {
  /// Creates a [BridgeRunFinished].
  const BridgeRunFinished({
    required this.threadId,
    required this.runId,
    this.value,
    this.printOutput,
  });

  /// Thread identifier.
  final String threadId;

  /// Run identifier.
  final String runId;

  /// The Python return value (when execution completed successfully).
  final Object? value;

  /// Captured print output (when available).
  final String? printOutput;
}

/// Execution failed with an error.
class BridgeRunError extends BridgeEvent {
  /// Creates a [BridgeRunError].
  const BridgeRunError({
    required this.message,
    this.printOutput,
    this.exception,
  });

  /// Error message.
  final String message;

  /// Captured print output before the error (when available).
  final String? printOutput;

  /// The original [MontyException] when the error originated from Python.
  ///
  /// Preserves structured fields (filename, lineNumber, excType, traceback)
  /// that are lost in the [message] string. Null when the error is not a
  /// Python exception (e.g. infrastructure errors).
  final MontyException? exception;
}

/// A host function call step started.
class BridgeStepStarted extends BridgeEvent {
  /// Creates a [BridgeStepStarted].
  const BridgeStepStarted({required this.stepId});

  /// Step identifier.
  final String stepId;
}

/// A host function call step finished.
class BridgeStepFinished extends BridgeEvent {
  /// Creates a [BridgeStepFinished].
  const BridgeStepFinished({required this.stepId});

  /// Step identifier.
  final String stepId;
}

/// A tool call began (function name known).
class BridgeToolCallStart extends BridgeEvent {
  /// Creates a [BridgeToolCallStart].
  const BridgeToolCallStart({required this.callId, required this.name});

  /// Call identifier.
  final String callId;

  /// Function name.
  final String name;
}

/// Tool call arguments (JSON delta).
class BridgeToolCallArgs extends BridgeEvent {
  /// Creates a [BridgeToolCallArgs].
  const BridgeToolCallArgs({required this.callId, required this.delta});

  /// Call identifier.
  final String callId;

  /// JSON argument delta.
  final String delta;
}

/// Tool call arguments complete.
class BridgeToolCallEnd extends BridgeEvent {
  /// Creates a [BridgeToolCallEnd].
  const BridgeToolCallEnd({required this.callId});

  /// Call identifier.
  final String callId;
}

/// Tool call result (handler output or error).
class BridgeToolCallResult extends BridgeEvent {
  /// Creates a [BridgeToolCallResult].
  const BridgeToolCallResult({required this.callId, required this.result});

  /// Call identifier.
  final String callId;

  /// Result string.
  final String result;
}

/// Text output started (print buffer flush).
class BridgeTextStart extends BridgeEvent {
  /// Creates a [BridgeTextStart].
  const BridgeTextStart({required this.messageId});

  /// Message identifier.
  final String messageId;
}

/// Text output content delta.
class BridgeTextContent extends BridgeEvent {
  /// Creates a [BridgeTextContent].
  const BridgeTextContent({required this.messageId, required this.delta});

  /// Message identifier.
  final String messageId;

  /// Text content delta.
  final String delta;
}

/// Text output ended.
class BridgeTextEnd extends BridgeEvent {
  /// Creates a [BridgeTextEnd].
  const BridgeTextEnd({required this.messageId});

  /// Message identifier.
  final String messageId;
}

/// Event loop entered wait state (Python called `wait_for_event()`).
class BridgeEventLoopWaiting extends BridgeEvent {
  /// Creates a [BridgeEventLoopWaiting].
  const BridgeEventLoopWaiting();
}

/// Event loop resumed after receiving a UI event.
class BridgeEventLoopResumed extends BridgeEvent {
  /// Creates a [BridgeEventLoopResumed].
  const BridgeEventLoopResumed({required this.event});

  /// The UI event map that was dispatched.
  final Map<String, dynamic> event;
}

/// Python called `render_ui` with a schema.
class BridgeUiRendered extends BridgeEvent {
  /// Creates a [BridgeUiRendered].
  const BridgeUiRendered({required this.schema});

  /// The UI schema map that was rendered.
  final Map<String, dynamic> schema;
}

/// An OS call started (Python accessed pathlib, os, datetime, etc.).
class BridgeOsCallStart extends BridgeEvent {
  /// Creates a [BridgeOsCallStart].
  const BridgeOsCallStart({
    required this.callId,
    required this.operationName,
  });

  /// Call identifier (bridge-assigned).
  final String callId;

  /// The OS operation name, e.g. `"Path.read_text"`, `"os.getenv"`.
  final String operationName;
}

/// An OS call completed with a result (or error string).
class BridgeOsCallResult extends BridgeEvent {
  /// Creates a [BridgeOsCallResult].
  const BridgeOsCallResult({required this.callId, required this.result});

  /// Call identifier (bridge-assigned).
  final String callId;

  /// Result string (or error description).
  final String result;
}
