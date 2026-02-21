import 'dart:typed_data';

/// Result of [NativeBindings.run].
///
/// Contains either a JSON result string or an error message.
final class RunResult {
  /// Creates a [RunResult].
  const RunResult({required this.tag, this.resultJson, this.errorMessage});

  /// `0` = OK, `1` = error.
  final int tag;

  /// JSON string with the execution result (when tag == 0).
  final String? resultJson;

  /// Error message (when tag == 1).
  final String? errorMessage;
}

/// Result of [NativeBindings.start], [NativeBindings.resume], and
/// [NativeBindings.resumeWithError].
///
/// Contains a progress tag and, depending on the tag, accessor data.
final class ProgressResult {
  /// Creates a [ProgressResult].
  const ProgressResult({
    required this.tag,
    this.functionName,
    this.argumentsJson,
    this.resultJson,
    this.isError,
    this.errorMessage,
  });

  /// `0` = complete, `1` = pending, `2` = error.
  final int tag;

  /// Pending external function name (when tag == 1).
  final String? functionName;

  /// Pending function arguments as JSON array (when tag == 1).
  final String? argumentsJson;

  /// Completed result as JSON string (when tag == 0).
  final String? resultJson;

  /// Whether the completed result is an error: `1` = yes, `0` = no,
  /// `-1` = not in complete state (when tag == 0).
  final int? isError;

  /// Error message from the C API (when tag == 2).
  final String? errorMessage;
}

/// Abstract interface over the 17 native C functions.
///
/// Uses `int` handles (the pointer address) instead of `Pointer<T>` types
/// so that the interface remains pure Dart and trivially mockable.
///
/// All memory management (C string allocation/deallocation, pointer
/// lifecycle) is the responsibility of the concrete implementation.
abstract class NativeBindings {
  /// Creates a handle from Python [code].
  ///
  /// If [externalFunctions] is non-null, it is a comma-separated list of
  /// external function names.
  ///
  /// Returns the handle address as an `int`, or throws on error.
  int create(String code, {String? externalFunctions});

  /// Frees the handle at [handle]. Safe to call with `0`.
  void free(int handle);

  /// Runs the handle to completion.
  RunResult run(int handle);

  /// Starts iterative execution. Returns progress with accessor data
  /// already populated.
  ProgressResult start(int handle);

  /// Resumes with a JSON-encoded return [valueJson].
  ProgressResult resume(int handle, String valueJson);

  /// Resumes with an [errorMessage] (raises RuntimeError in Python).
  ProgressResult resumeWithError(int handle, String errorMessage);

  /// Sets the memory limit in bytes.
  void setMemoryLimit(int handle, int bytes);

  /// Sets the execution time limit in milliseconds.
  void setTimeLimitMs(int handle, int ms);

  /// Sets the stack depth limit.
  void setStackLimit(int handle, int depth);

  /// Serializes the handle state to a byte buffer (snapshot).
  Uint8List snapshot(int handle);

  /// Restores a handle from snapshot [data].
  ///
  /// Returns the new handle address as an `int`, or throws on error.
  int restore(Uint8List data);
}
