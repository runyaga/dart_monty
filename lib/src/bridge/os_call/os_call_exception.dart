/// Base exception for OS call handler errors.
///
/// Thrown by `OsCallHandler` implementations to signal domain errors.
/// The bridge translates these into the corresponding Python exception
/// types when resuming execution.
class OsCallException implements Exception {
  /// Creates an [OsCallException] for the given [operation] and [message].
  const OsCallException(this.operation, this.message);

  /// The operation that failed (e.g., `Path.read_text`, `os.getenv`).
  final String operation;

  /// Human-readable error message.
  final String message;

  @override
  String toString() => 'OsCallException($operation): $message';
}

/// Thrown when an OS call is denied due to missing permissions or
/// an unconfigured handler.
class OsCallPermissionError extends OsCallException {
  /// Creates an [OsCallPermissionError] for the given [operation].
  const OsCallPermissionError(super.operation, super.message);

  @override
  String toString() => 'PermissionError($operation): $message';
}

/// Thrown when a file or directory referenced by an OS call does not exist.
class OsCallFileNotFoundError extends OsCallException {
  /// Creates an [OsCallFileNotFoundError] for the given [operation].
  const OsCallFileNotFoundError(super.operation, super.message);

  @override
  String toString() => 'FileNotFoundError($operation): $message';
}
