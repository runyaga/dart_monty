import 'dart:typed_data';

/// Result of [WasmBindings.run].
///
/// Contains either a successful value or an error message.
final class WasmRunResult {
  /// Creates a [WasmRunResult].
  const WasmRunResult({
    required this.ok,
    this.value,
    this.error,
    this.errorType,
    this.printOutput,
    this.excType,
    this.traceback,
    this.filename,
    this.lineNumber,
    this.columnNumber,
    this.sourceCode,
  });

  /// Whether the execution succeeded.
  final bool ok;

  /// The return value from the Python execution (when [ok] is true).
  final Object? value;

  /// Captured Python `print()` output (when [ok] is true).
  final String? printOutput;

  /// The error message (when [ok] is false).
  final String? error;

  /// The error type name (when [ok] is false).
  final String? errorType;

  /// The Python exception class name (when error occurred).
  final String? excType;

  /// The traceback frames as raw JSON list (when error occurred).
  final List<Object?>? traceback;

  /// Source filename (when [ok] is false).
  final String? filename;

  /// Source line number (when [ok] is false).
  final int? lineNumber;

  /// Source column number (when [ok] is false).
  final int? columnNumber;

  /// Source code at the error location (when [ok] is false).
  final String? sourceCode;
}

/// Result of [WasmBindings.start], [WasmBindings.resume], and
/// [WasmBindings.resumeWithError].
///
/// Contains a progress state and, depending on the state, accessor data.
final class WasmProgressResult {
  /// Creates a [WasmProgressResult].
  const WasmProgressResult({
    required this.ok,
    this.state,
    this.value,
    this.functionName,
    this.arguments,
    this.kwargs,
    this.callId,
    this.methodCall,
    this.printOutput,
    this.pendingCallIds,
    this.error,
    this.errorType,
    this.excType,
    this.traceback,
    this.filename,
    this.lineNumber,
    this.columnNumber,
    this.sourceCode,
  });

  /// Whether the operation succeeded.
  final bool ok;

  /// `'complete'`, `'pending'`, `'os_call'`,
  /// or `'resolve_futures'` (when [ok] is true).
  final String? state;

  /// The return value (when state is `'complete'`).
  final Object? value;

  /// Captured Python `print()` output (when state is `'complete'`).
  final String? printOutput;

  /// The external function name (when state is `'pending'`).
  final String? functionName;

  /// The function arguments (when state is `'pending'`).
  final List<Object?>? arguments;

  /// Keyword arguments from the Python call site (when state is `'pending'`).
  final Map<String, Object?>? kwargs;

  /// Unique call identifier (when state is `'pending'`).
  final int? callId;

  /// Whether this is a method call (when state is `'pending'`).
  final bool? methodCall;

  /// Pending future call IDs (when state is `'resolve_futures'`).
  final List<int>? pendingCallIds;

  /// The error message (when [ok] is false).
  final String? error;

  /// The error type name (when [ok] is false).
  final String? errorType;

  /// The Python exception class name (when error occurred).
  final String? excType;

  /// The traceback frames as raw JSON list (when error occurred).
  final List<Object?>? traceback;

  /// Source filename (when [ok] is false).
  final String? filename;

  /// Source line number (when [ok] is false).
  final int? lineNumber;

  /// Source column number (when [ok] is false).
  final int? columnNumber;

  /// Source code at the error location (when [ok] is false).
  final String? sourceCode;
}

/// Result of [WasmBindings.discover].
///
/// Describes the state of the WASM bridge.
final class WasmDiscoverResult {
  /// Creates a [WasmDiscoverResult].
  const WasmDiscoverResult({required this.loaded, required this.architecture});

  /// Whether the WASM module is loaded.
  final bool loaded;

  /// The bridge architecture (e.g. `'worker'`).
  final String architecture;
}

/// Abstract interface over the WASM bridge.
///
/// All methods are `Future`-based because the Worker round-trip is
/// inherently asynchronous. Each session maps to its own Worker hosting
/// an independent Monty WASM runtime.
///
/// Resource limits are passed inline with `run()` / `start()` calls
/// rather than via separate `setLimit` calls, avoiding extra Worker
/// round-trips.
abstract class WasmBindings {
  /// Creates a [WasmBindings].
  const WasmBindings();

  /// Initializes the WASM bridge (backward-compatible default session).
  ///
  /// Returns `true` if the Worker loaded successfully.
  Future<bool> init();

  /// Creates a new session with its own Worker.
  ///
  /// Returns the session ID for routing subsequent calls.
  Future<int> createSession();

  /// Disposes a session, terminating its Worker.
  Future<void> disposeSession(int sessionId);

  /// Runs Python [code] to completion.
  ///
  /// If [limitsJson] is non-null, it is a JSON-encoded map of limits.
  /// If [scriptName] is non-null, it overrides the default filename in
  /// tracebacks and error messages.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmRunResult> run(
    String code, {
    String? limitsJson,
    String? scriptName,
    int? sessionId,
  });

  /// Starts iterative execution of [code].
  ///
  /// If [extFnsJson] is non-null, it is a JSON array of external function
  /// names. If [limitsJson] is non-null, it is a JSON-encoded map of limits.
  /// If [scriptName] is non-null, it overrides the default filename.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> start(
    String code, {
    String? extFnsJson,
    String? limitsJson,
    String? scriptName,
    int? sessionId,
  });

  /// Resumes a paused execution with a JSON-encoded return [valueJson].
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> resume(String valueJson, {int? sessionId});

  /// Resumes a paused execution with an [errorMessage].
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> resumeWithError(
    String errorMessage, {
    int? sessionId,
  });

  /// Resumes by creating a future for the pending call.
  ///
  /// Returns a progress result which may be `pending` (next call),
  /// `resolve_futures` (all futures registered), or `complete`.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> resumeAsFuture({int? sessionId});

  /// Resolves pending futures with [resultsJson] and [errorsJson].
  ///
  /// [resultsJson] is a JSON object `{"callId": value, ...}`.
  /// [errorsJson] is a JSON object `{"callId": "errorMsg", ...}`.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson, {
    int? sessionId,
  });

  /// Captures the current interpreter state as a binary snapshot.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<Uint8List> snapshot({int? sessionId});

  /// Restores interpreter state from snapshot [data].
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<void> restore(Uint8List data, {int? sessionId});

  /// Discovers the bridge API surface.
  Future<WasmDiscoverResult> discover();

  /// Disposes the current Worker session.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<void> dispose({int? sessionId});

  // ---------------------------------------------------------------------------
  // REPL
  // ---------------------------------------------------------------------------

  /// Creates a persistent REPL session in the Worker.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<void> replCreate({String? scriptName, int? sessionId});

  /// Frees the REPL session in the Worker.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<void> replFree({int? sessionId});

  /// Feeds a Python snippet to the REPL and runs to completion.
  ///
  /// The REPL session survives -- state persists for subsequent calls.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmRunResult> replFeedRun(String code, {int? sessionId});

  /// Detects whether a source fragment is complete or needs more input.
  ///
  /// Returns `0` = complete, `1` = incomplete, `2` = incomplete block.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<int> replDetectContinuation(String source, {int? sessionId});

  /// Registers external function names for REPL name resolution.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<void> replSetExtFns(String extFns, {int? sessionId});

  /// Starts iterative REPL execution. Pauses at external function calls.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> replFeedStart(String code, {int? sessionId});

  /// Resumes REPL execution with a JSON-encoded return value.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> replResume(String valueJson, {int? sessionId});

  /// Resumes REPL execution with an error.
  ///
  /// When [sessionId] is non-null, routes to that specific session instead of
  /// the default.
  Future<WasmProgressResult> replResumeWithError(
    String errorJson, {
    int? sessionId,
  });
}
