import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:signals_core/signals_core.dart';

/// Plugin that intercepts and routes structured log output from Python code.
class LoggingPlugin extends MontyPlugin {
  /// Creates a [LoggingPlugin].
  ///
  /// [maxRecords] caps the in-memory ring buffer for [logSignal].
  /// [forwardToBridgeLogger] when true, forwards records to the bridge logger.
  /// [onRecord] optional callback for each received record.
  LoggingPlugin({
    this.maxRecords = 500,
    this.forwardToBridgeLogger = true,
    this.onRecord,
  });

  /// Preamble code to install the MontyHandler in Python.
  static const String montyHandlerPreamble = '''
import logging as _logging

class _MontyHandler(_logging.Handler):
    def emit(self, record):
        try:
            log_event(
                record.levelno,
                record.name,
                self.format(record),
                exc_info=self.formatException(record.exc_info) if record.exc_info else None,
            )
        except:
            pass # Avoid infinite recursion if log_event itself fails

_logging.getLogger().addHandler(_MontyHandler())
_logging.getLogger().setLevel(_logging.DEBUG)
''';

  /// Maximum number of records to keep in the ring buffer.
  final int maxRecords;

  /// Whether to forward records to the [BridgeLogger].
  final bool forwardToBridgeLogger;

  /// Optional callback invoked for every record.
  final void Function(LogRecord)? onRecord;

  final List<LogRecord> _records = [];
  final Signal<List<LogRecord>> _logSignal = signal([]);

  /// Reactive signal of recent log records, newest-last.
  ReadonlySignal<List<LogRecord>> get logSignal => _logSignal;

  @override
  String get namespace => 'log';

  @override
  String? get systemPromptContext =>
      'Emit structured log records from Python. '
      'Records include level, logger name, and message.';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _logEventSchema, handler: _handleLogEvent),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    // Children share the same record buffer and signal by default.
    return _SharedLoggingPlugin(this);
  }

  /// Clears the record buffer.
  void clearRecords() {
    _records.clear();
    _logSignal.value = List.unmodifiable(_records);
  }

  Future<Object?> _handleLogEvent(Map<String, Object?> args) {
    final record = LogRecord(
      level: args['level']! as int,
      loggerName: args['logger']! as String,
      message: args['message']! as String,
      timestamp: DateTime.now(),
      excInfo: args['exc_info'] as String?,
    );

    _addRecord(record);

    return Future.value();
  }

  void _addRecord(LogRecord record) {
    if (_records.length >= maxRecords) {
      _records.removeAt(0);
    }
    _records.add(record);
    _logSignal.value = List.unmodifiable(_records);

    if (forwardToBridgeLogger) {
      final subLogger = logger.child('python');
      switch (record.bridgeLevel) {
        case BridgeLogLevel.error:
          subLogger.error(
            record.message,
            attributes: {'logger': record.loggerName},
          );
        case BridgeLogLevel.warning:
          subLogger.warning(
            record.message,
            attributes: {'logger': record.loggerName},
          );
        case BridgeLogLevel.info:
          subLogger.info(
            record.message,
            attributes: {'logger': record.loggerName},
          );
        case BridgeLogLevel.debug:
          subLogger.debug(
            record.message,
            attributes: {'logger': record.loggerName},
          );
        case BridgeLogLevel.trace:
          subLogger.trace(
            record.message,
            attributes: {'logger': record.loggerName},
          );
      }
    }

    onRecord?.call(record);
  }
}

/// Internal helper to share state with children.
class _SharedLoggingPlugin extends MontyPlugin {
  _SharedLoggingPlugin(this._parent);
  final LoggingPlugin _parent;

  @override
  String get namespace => _parent.namespace;

  @override
  String? get systemPromptContext => _parent.systemPromptContext;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: _logEventSchema,
      handler: (args) {
        final record = LogRecord(
          level: args['level']! as int,
          loggerName: args['logger']! as String,
          message: args['message']! as String,
          timestamp: DateTime.now(),
          excInfo: args['exc_info'] as String?,
        );
        _parent._addRecord(record);

        return Future.value();
      },
    ),
  ];
}

/// Python logging level constants.
abstract class PythonLoggingLevels {
  /// DEBUG level (10).
  static const int debug = 10;

  /// INFO level (20).
  static const int info = 20;

  /// WARNING level (30).
  static const int warning = 30;

  /// ERROR level (40).
  static const int error = 40;

  /// CRITICAL level (50).
  static const int critical = 50;
}

/// A structured log record emitted by Python code.
class LogRecord {
  /// Creates a [LogRecord].
  const LogRecord({
    required this.level,
    required this.loggerName,
    required this.message,
    required this.timestamp,
    this.excInfo,
  });

  /// Python logging level integer (10, 20, 30, 40, 50).
  final int level;

  /// Logger name (e.g. 'root', or a dotted name like 'agent.fetch').
  final String loggerName;

  /// Formatted log message.
  final String message;

  /// Wall-clock time when the record was received by Dart.
  final DateTime timestamp;

  /// Formatted exception/traceback string, or null.
  final String? excInfo;

  /// Maps Python level integers to [BridgeLogLevel].
  BridgeLogLevel get bridgeLevel {
    if (level >= PythonLoggingLevels.critical) return BridgeLogLevel.error;
    if (level >= PythonLoggingLevels.error) return BridgeLogLevel.error;
    if (level >= PythonLoggingLevels.warning) return BridgeLogLevel.warning;
    if (level >= PythonLoggingLevels.info) return BridgeLogLevel.info;

    return BridgeLogLevel.debug;
  }
}

/// BridgeLogger level enum for mapping Python log levels to Dart log levels.
enum BridgeLogLevel {
  /// Trace-level log (finer than debug).
  trace,

  /// Debug-level log.
  debug,

  /// Informational log.
  info,

  /// Warning-level log.
  warning,

  /// Error-level log.
  error,
}

const _logEventSchema = HostFunctionSchema(
  name: 'log_event',
  description: 'Emit a structured log record from Python code.',
  params: [
    HostParam(
      name: 'level',
      type: HostParamType.integer,
      description:
          'Python logging level '
          '(10=DEBUG, 20=INFO, 30=WARNING, 40=ERROR, 50=CRITICAL).',
    ),
    HostParam(
      name: 'logger',
      type: HostParamType.string,
      description: 'Logger name.',
    ),
    HostParam(
      name: 'message',
      type: HostParamType.string,
      description: 'Formatted log message.',
    ),
    HostParam(
      name: 'exc_info',
      type: HostParamType.string,
      isRequired: false,
      description: 'Formatted exception/traceback string.',
    ),
  ],
);
