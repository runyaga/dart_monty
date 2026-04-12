import 'dart:async';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_host.dart';
import 'package:dart_monty/src/bridge/bridge/struct_log_bridge_logger.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:dart_monty/src/platform/monty_error.dart';
import 'package:dart_monty/src/platform/monty_exception.dart';
import 'package:dart_monty/src/platform/monty_future_capable.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_stack_frame.dart';
import 'package:meta/meta.dart';
import 'package:struct_log/struct_log.dart';

/// Print-override preamble injected before user code.
///
/// Routes Python `print()` calls through `__console_write__` so the bridge
/// can capture output and emit it as text events.
const _printPreamble = r'''
def _cw(*a, sep=' ', end='\n', **k):
    __console_write__(sep.join(str(x) for x in a) + end)
print = _cw
''';

/// Number of lines the preamble + separator add before user code.
///
/// The raw string literal opens with a newline after `r'''`, producing:
///   line 1: (empty)
///   line 2: def _cw(...)
///   line 3:     __console_write__(...)
///   line 4: print = _cw
///   line 5: (empty, closing `'''`)
/// Plus the `\n` in `'$_printPreamble\n$code'` = user code starts at line 6.
const _preambleLineCount = 5;

// ---------------------------------------------------------------------------
// Top-level helpers — pure utilities that do not need bridge instance state.
// ---------------------------------------------------------------------------

/// Adjusts [MontyException] line numbers to account for the print preamble
/// injected by [DefaultMontyBridge._run]. Filters preamble frames from the
/// traceback.
MontyException _adjustException(MontyException e) {
  return MontyException(
    message: e.message,
    filename: e.filename,
    lineNumber: e.lineNumber != null
        ? e.lineNumber! - _preambleLineCount
        : null,
    columnNumber: e.columnNumber,
    sourceCode: e.sourceCode,
    excType: e.excType,
    traceback: e.traceback
        .where((f) => f.startLine > _preambleLineCount)
        .map(
          (f) => MontyStackFrame(
            filename: f.filename,
            startLine: f.startLine - _preambleLineCount,
            startColumn: f.startColumn,
            endLine: f.endLine != null
                ? f.endLine! - _preambleLineCount
                : null,
            endColumn: f.endColumn,
            frameName: f.frameName,
            previewLine: f.previewLine,
            hideCaret: f.hideCaret,
            hideFrameName: f.hideFrameName,
          ),
        )
        .toList(),
  );
}

/// Flushes buffered print output as [BridgeTextStart]/[BridgeTextContent]/
/// [BridgeTextEnd] events. No-op if [buffer] is empty.
void _flushPrintBuffer(
  StringBuffer buffer,
  StreamController<BridgeEvent> controller,
  String messageId,
) {
  if (buffer.isEmpty) return;
  controller
    ..add(BridgeTextStart(messageId: messageId))
    ..add(BridgeTextContent(messageId: messageId, delta: buffer.toString()))
    ..add(BridgeTextEnd(messageId: messageId));
}

/// Handles the [MontyComplete] terminal step — flushes print output, emits
/// [BridgeRunFinished] or [BridgeRunError] depending on the result.
void _emitComplete(
  MontyComplete complete,
  StringBuffer printBuffer,
  StreamController<BridgeEvent> controller,
  String threadId,
  String runId,
  String messageId,
) {
  _flushPrintBuffer(printBuffer, controller, messageId);
  final capturedOutput = printBuffer.isNotEmpty
      ? printBuffer.toString()
      : complete.result.printOutput;

  if (complete.result.isError) {
    final adjusted = _adjustException(complete.result.error!);
    controller.add(
      BridgeRunError(
        message: adjusted.message,
        printOutput: capturedOutput,
        exception: adjusted,
      ),
    );
  } else {
    controller.add(
      BridgeRunFinished(
        threadId: threadId,
        runId: runId,
        value: complete.result.value?.dartValue,
        printOutput: capturedOutput,
      ),
    );
  }
}

/// Emits a [BridgeRunError] for a [MontyScriptError] caught during `_run`.
void _emitScriptError(
  MontyScriptError e,
  StringBuffer printBuffer,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
  String messageId,
) {
  final adjusted = e.exception != null ? _adjustException(e.exception!) : null;
  log.warning(
    'Python error',
    attributes: {'error': adjusted?.message ?? e.message},
  );
  _flushPrintBuffer(printBuffer, controller, messageId);
  final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
  controller.add(
    BridgeRunError(
      message: adjusted?.message ?? e.message,
      printOutput: output,
      exception: adjusted,
    ),
  );
}

/// Emits a [BridgeRunError] for a [MontyError] caught during `_run`.
void _emitMontyError(
  MontyError e,
  StringBuffer printBuffer,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
  String messageId,
) {
  log.warning('Monty error', attributes: {'error': e.message});
  _flushPrintBuffer(printBuffer, controller, messageId);
  final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
  controller.add(BridgeRunError(message: e.message, printOutput: output));
}

/// Emits a [BridgeRunError] for an unexpected [Object] caught during `_run`.
void _emitInfraError(
  Object e,
  StackTrace stackTrace,
  StringBuffer printBuffer,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
  String messageId,
) {
  log.error('Bridge infrastructure error', error: e, stackTrace: stackTrace);
  _flushPrintBuffer(printBuffer, controller, messageId);
  final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
  controller.add(BridgeRunError(message: '$e', printOutput: output));
}

// ---------------------------------------------------------------------------
// DefaultMontyBridge — thin coordinator.
// ---------------------------------------------------------------------------

/// Default [MontyBridge] implementation.
///
/// Orchestrates the Monty start/resume loop and delegates function
/// registration and tool dispatch to a [PluginHost].
class DefaultMontyBridge implements MontyBridge {
  /// Creates a [DefaultMontyBridge].
  ///
  /// Pass [logger] to inject a custom [BridgeLogger] for this bridge instance.
  /// If omitted, defaults to struct_log via [StructLogBridgeLogger].
  ///
  /// To silence logging entirely, pass `const NullBridgeLogger()`.
  DefaultMontyBridge({
    required MontyPlatform platform,
    MontyLimits? limits,
    bool useFutures = true,
    BridgeLogger? logger,
  }) : _platform = platform,
       _limits = limits,
       _useFutures = useFutures,
       log = logger ?? StructLogBridgeLogger.root(LogManager.instance) {
    _host = PluginHost(platform: platform, log: log);
  }

  /// Logger for this bridge instance.
  @protected
  final BridgeLogger log;

  final MontyPlatform _platform;
  final MontyLimits? _limits;
  final bool _useFutures;
  late final PluginHost _host;

  // Kept separately from PluginHost._osProvider so dispose() can call it
  // without accessing PluginHost internals.
  OsProvider? _osProvider;

  bool _isExecuting = false;
  bool _isDisposed = false;

  @override
  BridgeLogger get logger => log;

  // ---------------------------------------------------------------------------
  // MontyBridge interface — delegated to PluginHost.
  // ---------------------------------------------------------------------------

  @override
  List<HostFunctionSchema> get schemas => _host.schemas;

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory =>
      _host.schemasByCategory;

  @override
  void use(BridgeMiddleware middleware) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _host.use(middleware);
  }

  @override
  void register(HostFunction function, {String? category}) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _host.register(function, category: category);
  }

  @override
  void unregister(String name) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _host.unregister(name);
  }

  @override
  void registerOs(OsProvider provider) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _osProvider = provider;
    _host.registerOs(provider);
  }

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    CallRole role = const ToolCall(),
  }) {
    if (_isDisposed) throw StateError('Bridge has been disposed');

    return _host.invokeHostFunction(name, args, role: role);
  }

  // ---------------------------------------------------------------------------
  // Execution.
  // ---------------------------------------------------------------------------

  @override
  Stream<BridgeEvent> execute(String code) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    if (_isExecuting) throw StateError('Bridge is already executing');
    log.debug('Executing code', attributes: {'codeLength': code.length});

    final controller = StreamController<BridgeEvent>();
    _isExecuting = true;
    unawaited(
      _run(code, controller).whenComplete(() {
        _isExecuting = false;
        unawaited(controller.close());
      }),
    );

    return controller.stream;
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_osProvider?.dispose());
    log.close();
  }

  // ---------------------------------------------------------------------------
  // Internal execution loop.
  // ---------------------------------------------------------------------------

  Future<void> _run(
    String code,
    StreamController<BridgeEvent> controller,
  ) async {
    final printBuffer = StringBuffer();
    try {
      final init = await _initExecution(code, controller);
      var progress = init.progress;
      while (true) {
        final next = await _dispatchProgress(
          progress,
          controller,
          printBuffer,
          init.threadId,
          init.runId,
          futuresCapable: init.futuresCapable,
        );
        if (next == null) return;
        progress = next;
      }
    } on MontyScriptError catch (e) {
      _emitScriptError(e, printBuffer, controller, log, _host.nextId);
    } on MontyError catch (e) {
      _emitMontyError(e, printBuffer, controller, log, _host.nextId);
    } on Object catch (e, st) {
      _emitInfraError(e, st, printBuffer, controller, log, _host.nextId);
    } finally {
      _host.clearPendingFutures();
    }
  }

  Future<
    ({
      MontyProgress progress,
      String threadId,
      String runId,
      bool futuresCapable,
    })
  >
  _initExecution(String code, StreamController<BridgeEvent> controller) async {
    final threadId = _host.nextId;
    final runId = _host.nextId;
    controller.add(BridgeRunStarted(threadId: threadId, runId: runId));

    final wrappedCode = '$_printPreamble\n$code';
    final externalFunctions = [
      '__console_write__',
      ..._host.schemas.map((s) => s.name),
    ];
    final futuresCapable = _useFutures && _platform is MontyFutureCapable;
    _host.clearPendingFutures();

    final progress = await _platform.start(
      wrappedCode,
      externalFunctions: externalFunctions,
      limits: _limits,
    );

    return (
      progress: progress,
      threadId: threadId,
      runId: runId,
      futuresCapable: futuresCapable,
    );
  }

  Future<MontyProgress?> _dispatchProgress(
    MontyProgress progress,
    StreamController<BridgeEvent> controller,
    StringBuffer printBuffer,
    String threadId,
    String runId, {
    required bool futuresCapable,
  }) async {
    switch (progress) {
      case final MontyPending pending:
        return _host.handlePending(
          pending,
          printBuffer,
          controller,
          futuresCapable: futuresCapable,
        );
      case final MontyOsCall osCall:
        return _host.handleOsCall(osCall, controller);
      case final MontyResolveFutures resolve:
        return futuresCapable
            ? _host.resolveFutures(resolve, controller)
            : _platform.resume(null);
      case final MontyComplete complete:
        _emitComplete(
          complete,
          printBuffer,
          controller,
          threadId,
          runId,
          _host.nextId,
        );

        return null;
    }
  }
}
