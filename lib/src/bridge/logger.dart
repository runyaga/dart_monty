/// Minimal structured logging interface for the Monty ecosystem.
///
/// A `null` logger selects dm's default, backed by struct_log under the
/// root name `monty` (works on FFI and WASM); [silent] discards everything.
///
/// Override: implement this interface to bring your own logging framework.
abstract interface class BridgeLogger {
  /// A logger that discards everything: [child] returns it, and [close]
  /// does nothing.
  static const BridgeLogger silent = _SilentBridgeLogger();

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

/// [BridgeLogger.silent]: discards all messages.
final class _SilentBridgeLogger implements BridgeLogger {
  const _SilentBridgeLogger();

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
