/// Minimal structured logging interface for the Monty ecosystem.
///
/// Default implementation: `StructLogBridgeLogger` in `dart_monty_bridge`
/// (backed by struct_log, works on FFI and WASM).
///
/// Override: implement this interface to bring your own logging framework.
/// See `NullBridgeLogger` for a silent no-op implementation.
abstract interface class BridgeLogger {
  /// Logs a trace-level message (finest granularity).
  void trace(String message, {Map<String, Object?>? attributes});

  /// Logs a debug-level message.
  void debug(String message, {Map<String, Object?>? attributes});

  /// Logs an info-level message.
  void info(String message, {Map<String, Object?>? attributes});

  /// Logs a warning-level message.
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  });

  /// Logs an error-level message.
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  });

  /// Creates a child logger with a hierarchical name.
  ///
  /// Example: `logger.child('sandbox').child('child.0')` produces
  /// a logger named `root.sandbox.child.0`.
  BridgeLogger child(String name);

  /// Marks this logger (and all children created via [child]) as closed.
  ///
  /// After [close], all log methods become no-ops. This prevents late
  /// Future resolutions from writing to disposed sinks.
  ///
  /// Implementations that don't need cleanup can make this a no-op.
  void close();
}

/// A logger that silently discards all messages.
///
/// Use this to explicitly silence logging, or as a safe default when
/// no logging is configured.
class NullBridgeLogger implements BridgeLogger {
  /// Creates a null logger. Use [const NullBridgeLogger()] for zero
  /// allocation.
  const NullBridgeLogger();

  @override
  void trace(String message, {Map<String, Object?>? attributes}) {}

  @override
  void debug(String message, {Map<String, Object?>? attributes}) {}

  @override
  void info(String message, {Map<String, Object?>? attributes}) {}

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {}

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {}

  @override
  BridgeLogger child(String name) => this;

  @override
  void close() {}
}
