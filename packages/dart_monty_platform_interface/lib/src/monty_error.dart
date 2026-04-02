import 'package:dart_monty_platform_interface/src/monty_exception.dart';

/// Sealed error hierarchy for Monty interpreter failures.
///
/// Use exhaustive pattern matching to handle all failure modes:
///
/// ```dart
/// try {
///   await platform.run(code);
/// } on MontyError catch (e) {
///   switch (e) {
///     case MontyCancelledError():   // Supervisor-initiated cancel
///     case MontyScriptError():      // Python exception
///     case MontyPanicError():       // Rust panic
///     case MontyCrashError():       // Isolate died unexpectedly
///     case MontyDisposedError():    // Disposed while running
///     case MontyResourceError():    // OOM, timeout, WASM trap
///   }
/// }
/// ```
sealed class MontyError implements Exception {
  /// Creates a [MontyError] with the given [message].
  const MontyError(this.message);

  /// Human-readable description of the error.
  final String message;

  /// Subclass name for toString. Overridden by each subtype.
  String get _typeName => 'MontyError';

  @override
  String toString() => '$_typeName: $message';
}

/// Thrown when execution is cancelled via cancel() or cancelById().
///
/// **Supervisor action:** Expected — no restart needed.
class MontyCancelledError extends MontyError {
  /// Creates a [MontyCancelledError].
  const MontyCancelledError([super.message = 'Execution cancelled']);

  @override
  String get _typeName => 'MontyCancelledError';
}

/// Thrown when the interpreter hits a Python-level exception.
///
/// Carries the full [MontyException] for access to traceback, source
/// location, and the Python exception class name.
///
/// **Application error** — handled by orchestrator/saga, NOT supervisor.
/// Do not restart blindly — Python exceptions are deterministic.
class MontyScriptError extends MontyError {
  /// Creates a [MontyScriptError] from a [MontyException].
  MontyScriptError(this.exception)
      : excType = exception.excType,
        super(exception.message);

  /// The full Python exception with traceback, source location, etc.
  final MontyException exception;

  /// The Python exception class name (e.g. "ZeroDivisionError").
  final String? excType;

  @override
  String get _typeName => 'MontyScriptError';
}

/// Thrown when the Rust interpreter panics (caught by catch_unwind).
///
/// **Supervisor action:** Harsh backoff — indicates a native bridge bug.
class MontyPanicError extends MontyError {
  /// Creates a [MontyPanicError].
  const MontyPanicError(super.message);

  @override
  String get _typeName => 'MontyPanicError';
}

/// Thrown when the isolate/Worker died unexpectedly.
///
/// **Supervisor action:** Restart immediately (infrastructure failure).
class MontyCrashError extends MontyError {
  /// Creates a [MontyCrashError].
  const MontyCrashError([super.message = 'Interpreter crashed unexpectedly']);

  @override
  String get _typeName => 'MontyCrashError';
}

/// Thrown when the interpreter is disposed while execution is in flight.
///
/// **Supervisor action:** Do NOT restart — fix the caller.
class MontyDisposedError extends MontyError {
  /// Creates a [MontyDisposedError].
  const MontyDisposedError([
    super.message = 'Interpreter disposed during execution',
  ]);

  @override
  String get _typeName => 'MontyDisposedError';
}

/// Thrown on resource exhaustion: OOM, timeout, WASM trap.
///
/// **Supervisor action:** Reduce concurrency, then restart.
class MontyResourceError extends MontyError {
  /// Creates a [MontyResourceError].
  const MontyResourceError(super.message);

  @override
  String get _typeName => 'MontyResourceError';
}
