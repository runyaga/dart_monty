import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:struct_log/struct_log.dart';

/// Default [BridgeLogger] backed by struct_log.
///
/// This is the batteries-included logger for the Monty bridge ecosystem.
/// Works on both FFI (native console/file sinks) and WASM (browser console
/// sink via dart:js_interop).
///
/// Use [StructLogBridgeLogger.root] to create a root logger from a
/// [LogManager]. Child loggers are created via [child] and form a
/// hierarchical tree (e.g., `monty.sandbox.child.0.fs`).
class StructLogBridgeLogger implements BridgeLogger {
  /// Creates a logger wrapping a struct_log [Logger].
  StructLogBridgeLogger(this._logger, this._logManager);

  /// Creates a root logger from a [LogManager].
  ///
  /// ```dart
  /// final logger = StructLogBridgeLogger.root(LogManager.instance);
  /// // or for test isolation:
  /// final logger = StructLogBridgeLogger.root(LogManager.scoped(), 'test');
  /// ```
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
    if (_disposed) return const NullBridgeLogger();
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
