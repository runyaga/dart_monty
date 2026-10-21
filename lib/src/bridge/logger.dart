/// Accepts structured bridge log records.
abstract interface class BridgeLogger {
  /// Discards all records and cleanup requests.
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

  /// Creates a hierarchically named child logger.
  BridgeLogger child(String name);

  /// Stops this logger and its children from accepting records.
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
