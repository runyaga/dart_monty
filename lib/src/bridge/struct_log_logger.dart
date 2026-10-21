import 'package:dart_monty/src/bridge/logger.dart';
import 'package:struct_log/struct_log.dart';

/// Adapts struct_log to hierarchical bridge logging on native and web targets.
class StructLogBridgeLogger implements BridgeLogger {
  /// Creates a logger wrapping a struct_log [Logger].
  StructLogBridgeLogger(this._logger, this._logManager);

  /// Creates a named root logger from a log manager.
  factory StructLogBridgeLogger.root(
    LogManager logManager, [
    String name = 'monty',
  ]) => StructLogBridgeLogger(logManager.getLogger(name), logManager);

  final Logger _logger;
  final LogManager _logManager;
  bool _disposed = false;
  final List<StructLogBridgeLogger> _children = [];

  @override
  void trace(String message, {Map<String, Object?>? attributes}) {
    if (_disposed) return;
    _logger.trace(message, attributes: attributes);
  }

  @override
  void debug(String message, {Map<String, Object?>? attributes}) {
    if (_disposed) return;
    _logger.debug(message, attributes: attributes);
  }

  @override
  void info(String message, {Map<String, Object?>? attributes}) {
    if (_disposed) return;
    _logger.info(message, attributes: attributes);
  }

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    if (_disposed) return;
    _logger.warning(
      message,
      error: error,
      stackTrace: stackTrace,
      attributes: attributes,
    );
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) {
    if (_disposed) return;
    _logger.error(
      message,
      error: error,
      stackTrace: stackTrace,
      attributes: attributes,
    );
  }

  @override
  BridgeLogger child(String name) {
    if (_disposed) return BridgeLogger.silent;
    final child = StructLogBridgeLogger(
      _logManager.getLogger('${_logger.name}.$name'),
      _logManager,
    );
    _children.add(child);

    return child;
  }

  @override
  void close() {
    _disposed = true;
    for (final child in _children) {
      child.close();
    }
    _children.clear();
  }
}
