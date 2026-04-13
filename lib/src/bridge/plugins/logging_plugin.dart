import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart';

/// Plugin for capturing structured logs from Python.
class LoggingPlugin extends MontyPlugin {
  /// Creates a [LoggingPlugin].
  LoggingPlugin({
    this.maxRecords = 500,
    this.forwardToBridgeLogger = true,
    this.onRecord,
  });

  /// Maximum number of log records to keep in the reactive [logSignal].
  final int maxRecords;

  /// Whether to forward captured Python logs to the [BridgeLogger].
  final bool forwardToBridgeLogger;

  /// Optional callback invoked for every log record received.
  final void Function(LogRecord)? onRecord;

  /// Reactive list of recently captured log records.
  final ReadonlySignal<List<LogRecord>> logSignal = signal(const []);

  /// Python preamble to install MontyHandler.
  static const String pythonPreamble = '''
import logging as _logging

class _MontyHandler(_logging.Handler):
    def __init__(self):
        super().__init__()
        self._batch = []

    def emit(self, record):
        try:
            entry = {
                'level': record.levelno,
                'logger': record.name,
                'message': self.format(record),
                'exc_info': self.formatException(record.exc_info) if record.exc_info else None,
            }
            self._batch.append(entry)
            if len(self._batch) >= 10:
                self.flush()
        except Exception:
            self.handleError(record)

    def flush(self):
        if self._batch:
            try:
                log_log_event_batch(batch=self._batch)
                self._batch = []
            except Exception:
                pass

_monty_handler = _MontyHandler()
_logging.getLogger().addHandler(_monty_handler)
_logging.getLogger().setLevel(_logging.DEBUG)

# Ensure flush on exit if possible, though host hooks handle this too.
import atexit as _atexit
_atexit.register(_monty_handler.flush)
''';

  final List<LogRecord> _buffer = [];

  Signal<List<LogRecord>> get _logSignal =>
      logSignal as Signal<List<LogRecord>>;

  @override
  String get namespace => 'log';

  @override
  bool get hasExecuteHooks => false;

  @override
  String? get systemPromptContext =>
      'Capture structured logs from Python using the logging module. '
      'Records are available in the host logSignal.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: _logEventBatchSchema,
      handler: _handleLogEventBatch,
    ),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    // Shared signal/buffer for children.
    return _ChildLoggingPlugin(parent: this);
  }

  void _addRecord(LogRecord record) {
    if (_buffer.length >= maxRecords) {
      _buffer.removeAt(0);
    }
    _buffer.add(record);
    _logSignal.value = List.from(_buffer);

    onRecord?.call(record);

    if (forwardToBridgeLogger) {
      final bridgeLogger = logger.child('python');
      final msg = '[${record.loggerName}] ${record.message}';
      final attr = {'python_level': record.level};

      if (record.level >= 40) {
        bridgeLogger.error(msg, attributes: attr, error: record.excInfo);
      } else if (record.level >= 30) {
        bridgeLogger.warning(msg, attributes: attr);
      } else if (record.level >= 20) {
        bridgeLogger.info(msg, attributes: attr);
      } else {
        bridgeLogger.debug(msg, attributes: attr);
      }
    }
  }

  Future<Object?> _handleLogEventBatch(Map<String, Object?> args) {
    final batch = args['batch']! as List<Object?>;
    for (final item in batch) {
      if (item is Map<String, Object?>) {
        final record = LogRecord(
          level: item['level'] as int? ?? 20,
          loggerName: item['logger'] as String? ?? 'root',
          message: item['message'] as String? ?? '',
          timestamp: DateTime.now(),
          excInfo: item['exc_info'] as String?,
        );
        _addRecord(record);
      }
    }

    return Future.value();
  }
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

  /// The severity level of the log record (using Python logging levels).
  final int level;

  /// The name of the Python logger that emitted this record.
  final String loggerName;

  /// The formatted log message.
  final String message;

  /// When the log record was received by the bridge.
  final DateTime timestamp;

  /// Formatted exception info/traceback, if any.
  final String? excInfo;

  /// Converts the record to a map for serialization.
  Map<String, Object?> toMap() => {
    'level': level,
    'logger': loggerName,
    'message': message,
    'timestamp': timestamp.toIso8601String(),
    'exc_info': excInfo,
  };
}

class _ChildLoggingPlugin extends MontyPlugin {
  _ChildLoggingPlugin({required this.parent});
  final LoggingPlugin parent;

  @override
  String get namespace => parent.namespace;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: _logEventBatchSchema,
      handler: parent._handleLogEventBatch,
    ),
  ];
}

const _logEventBatchSchema = HostFunctionSchema(
  name: 'log_event_batch',
  description: 'Emit a batch of structured log records.',
  params: [
    HostParam(
      name: 'batch',
      type: HostParamType.any,
      description: 'List of log entry dicts.',
    ),
  ],
);
