import 'package:dart_monty/dart_monty_bridge.dart' show HostContext;
import 'package:dart_monty/src/host/context.dart' show HostContext;
import 'package:dart_monty_core/dart_monty_core.dart';

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
    this.montyValue,
    this.printOutput,
  });

  /// Thread identifier.
  final String threadId;

  /// Run identifier.
  final String runId;

  /// The Python return value as a plain Dart value (collections
  /// recursively unwrapped). Loses `__type` envelopes — a Python
  /// dataclass returns as a `Map<String, Object?>` here. Suitable for
  /// telemetry and UI display.
  final Object? value;

  /// The Python return value as a typed [MontyValue], preserving
  /// `__type` envelopes (e.g. `MontyDataclass`, `MontyNamedTuple`).
  /// Use this when downstream code needs to distinguish typed values
  /// from plain dicts.
  final MontyValue? montyValue;

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

/// A host function call started (wraps start through result).
class BridgeCallStarted extends BridgeEvent {
  /// Creates a [BridgeCallStarted].
  const BridgeCallStarted({required this.callId});

  /// Call identifier (matches [BridgeFunctionCallStart.name]).
  final String callId;
}

/// A host function call finished (wraps start through result).
class BridgeCallFinished extends BridgeEvent {
  /// Creates a [BridgeCallFinished].
  const BridgeCallFinished({required this.callId});

  /// Call identifier (matches [BridgeFunctionCallStart.name]).
  final String callId;
}

/// A host function call began (function name known).
class BridgeFunctionCallStart extends BridgeEvent {
  /// Creates a [BridgeFunctionCallStart].
  const BridgeFunctionCallStart({required this.callId, required this.name});

  /// Call identifier.
  final String callId;

  /// Function name.
  final String name;
}

/// Host function call arguments (JSON delta).
class BridgeFunctionCallArgs extends BridgeEvent {
  /// Creates a [BridgeFunctionCallArgs].
  const BridgeFunctionCallArgs({required this.callId, required this.delta});

  /// Call identifier.
  final String callId;

  /// JSON argument delta.
  final String delta;
}

/// Host function call arguments complete.
class BridgeFunctionCallEnd extends BridgeEvent {
  /// Creates a [BridgeFunctionCallEnd].
  const BridgeFunctionCallEnd({required this.callId});

  /// Call identifier.
  final String callId;
}

/// Host function call result (handler output or error).
class BridgeFunctionCallResult extends BridgeEvent {
  /// Creates a [BridgeFunctionCallResult].
  const BridgeFunctionCallResult({required this.callId, required this.result});

  /// Call identifier.
  final String callId;

  /// Result string.
  final String result;
}

/// Intermediate text emitted by a host function handler via [HostContext.emit].
///
/// Emitted mid-call for streaming progress updates or partial results.
/// Arrives between [BridgeFunctionCallStart] and [BridgeFunctionCallResult].
class BridgeFunctionEmit extends BridgeEvent {
  /// Creates a [BridgeFunctionEmit].
  const BridgeFunctionEmit({required this.callId, required this.text});

  /// Call identifier — matches the enclosing [BridgeFunctionCallStart.callId].
  final String callId;

  /// Emitted text.
  final String text;
}

/// An OS call started (Python accessed pathlib, os, datetime, etc.).
class BridgeOsCallStart extends BridgeEvent {
  /// Creates a [BridgeOsCallStart].
  const BridgeOsCallStart({
    required this.callId,
    required this.operationName,
    this.argumentSummary,
  });

  /// Call identifier (bridge-assigned).
  final String callId;

  /// The OS operation name, e.g. `"Path.read_text"`, `"os.getenv"`.
  final String operationName;

  /// Human-readable summary of the call's arguments (for telemetry).
  ///
  /// Example: `"'/sandbox/test.txt'"` for a read_text call.
  /// May be null for calls with no arguments.
  final String? argumentSummary;
}

/// Wraps an event re-emitted from a child runtime on its parent's stream.
///
/// Used by child-spawning plugins (e.g. `SandboxExtension`) to aggregate child
/// execution events into the parent runtime's broadcast `events` stream so
/// observers see a single, attributed ordering across the ownership tree.
class BridgeChildEvent extends BridgeEvent {
  /// Creates a [BridgeChildEvent].
  const BridgeChildEvent({required this.childHandle, required this.inner});

  /// Identifier of the child that produced [inner] (namespace-local to the
  /// plugin that spawned the child, e.g. a sandbox child id).
  final String childHandle;

  /// The original event emitted by the child.
  final BridgeEvent inner;
}

/// An OS call completed with a result (or error string).
class BridgeOsCallResult extends BridgeEvent {
  /// Creates a [BridgeOsCallResult].
  const BridgeOsCallResult({
    required this.callId,
    required this.result,
    this.durationMs,
  });

  /// Call identifier (bridge-assigned).
  final String callId;

  /// Result string (or error description).
  final String result;

  /// Wall-clock duration of the handler invocation in milliseconds.
  ///
  /// Null when the call was rejected (no handler registered).
  final int? durationMs;
}
