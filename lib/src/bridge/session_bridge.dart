import 'dart:async';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/run_failure.dart';
import 'package:dart_monty/src/bridge/struct_log_logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';
import 'package:struct_log/struct_log.dart';

/// `excType: message` for [BridgeRunError.message], or the message alone
/// when the type is empty.
String _composeMessage(String excType, String message) =>
    excType.isEmpty ? message : '$excType: $message';

/// The collected print text, or null when nothing was printed.
String? _printed(CollectString collector) {
  final text = collector.output;

  return text.isEmpty ? null : text;
}

/// The [MontyBridge] implementation: runs its code on a [MontySession].
///
/// Each [execute] is one `feedRun` on the session. Core has no event stream,
/// so the bridge builds its own: it wraps the [OsHandler] it passes to the
/// feed, and collects print text through the feed's print callback. Calls
/// the worker answers itself (mounts, the OS policy, the default for a
/// declined call) never reach the bridge and emit no events.
@internal
class SessionBridge implements MontyBridge {
  /// Creates a bridge over [session]; [subExecute] is every handler's
  /// [HostContext.subExecute] (none when null).
  SessionBridge({
    required this.session,
    // ignore: unnecessary-optional-parameters, tests build a bridge without a logger.
    BridgeLogger? logger,
    // ignore: unnecessary-nullable-parameters, unnecessary-optional-parameters, redirecting MontyBridge factory omits runtime.
    MontyRuntimeRef? runtime,
    // ignore: unnecessary-nullable-parameters, unnecessary-optional-parameters, redirecting MontyBridge factory omits subExecute.
    RuntimeSubExecutor? subExecute,
  }) : logger = logger ?? StructLogBridgeLogger.root(LogManager.instance),
       _host = HostDispatch(
         log: logger ?? StructLogBridgeLogger.root(LogManager.instance),
         runtime: runtime,
         subExecute: subExecute,
       );

  /// The session this bridge runs code on.
  ///
  /// A shared-mode runtime replaces it with a fresh checkout after a cancel
  /// closed the one before; the functions and extensions stay registered.
  @internal
  // ignore: dispose-class-fields, the runtime that checked it out closes it.
  MontySession session;

  @override
  final BridgeLogger logger;

  final HostDispatch _host;

  OsHandler? _currentOsHandler;

  /// The execution in progress, or null: a token per [execute].
  Object? _activeRun;
  bool _isDisposed = false;

  // Stream wrappers registered by extensions that override
  // wrapExecuteStream. Each wraps the stream the one before it returned, so
  // the last registered is outermost.
  final List<Stream<BridgeEvent> Function(String, Stream<BridgeEvent>)>
  _streamWrappers = [];

  /// Registers a stream wrapper callback from an extension.
  @internal
  void addStreamWrapper(
    Stream<BridgeEvent> Function(String code, Stream<BridgeEvent> stream)
    wrapper,
  ) {
    _streamWrappers.add(wrapper);
  }

  @override
  List<HostFunctionSchema> get schemas => _host.schemas;

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory =>
      _host.schemasByCategory;

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
  void registerOs(OsHandler handler) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _currentOsHandler = handler;
    _host.osHandler = handler;
  }

  /// Replaces the currently-registered OS handler with [handler] (or clears
  /// it when `null`).
  @internal
  // ignore: unnecessarily-public-code, tests exercise clearing and restoring handlers.
  void setOsHandler(OsHandler? handler) {
    if (_isDisposed) return;
    _currentOsHandler = handler;
    _host.osHandler = handler;
  }

  /// The currently-registered OS handler, if any.
  @internal
  // ignore: unnecessarily-public-code, tests inspect handler restoration.
  OsHandler? get currentOsHandler => _currentOsHandler;

  @override
  Future<MontyValue> invokeHostFunction(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  }) {
    if (_isDisposed) throw StateError('Bridge has been disposed');

    return _host.invokeHostFunction(name, args, onEvent: onEvent);
  }

  @override
  Stream<BridgeEvent> execute(String code) => executeWith(code);

  /// [execute], with the feed's [inputs], an [os] handler in place of the
  /// registered one for this run only, and the [cancelToken] each host
  /// function call of the run sees as `HostContext.cancelToken`.
  @internal
  Stream<BridgeEvent> executeWith(
    String code, {
    Map<String, MontyValue>? inputs,
    OsHandler? os,
    CancelToken? cancelToken,
    String? cwd,
  }) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    if (_activeRun != null) throw StateError('Bridge is already executing');
    logger.debug('Executing code', attributes: {'codeLength': code.length});

    final controller = StreamController<BridgeEvent>();
    final run = Object();
    _activeRun = run;
    void release() {
      if (identical(_activeRun, run)) _activeRun = null;
    }

    // The wrappers are applied before the feed starts: one that throws
    // frees the bridge at once, and the session is never fed.
    final stream = _wrapStream(code, controller, _streamWrappers, release);

    unawaited(
      _run(
        code,
        controller,
        inputs: inputs,
        os: os ?? _currentOsHandler,
        cancelToken: cancelToken,
        cwd: cwd,
      ).whenComplete(() {
        release();
        unawaited(controller.close());
      }),
    );

    return stream;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _currentOsHandler = null;
    _host.osHandler = null;
    logger.close();
  }

  /// Runs [code] as one feed on [session], adding its events to
  /// [controller]: [BridgeRunStarted] first, then the OS-call events, then
  /// [BridgeRunFinished] or [BridgeRunError].
  ///
  /// Each event is logged when it is emitted, whether or not the stream is
  /// listened to. Nothing is emitted after the terminal event: an OS
  /// handler that settles after its feed ended (the session was closed
  /// meanwhile) reports nothing.
  Future<void> _run(
    String code,
    StreamController<BridgeEvent> controller, {
    required Map<String, MontyValue>? inputs,
    required OsHandler? os,
    required CancelToken? cancelToken,
    required String? cwd,
  }) async {
    var ended = false;
    void emit(BridgeEvent event) {
      if (ended) return;
      _logEvent(logger, event);
      controller.add(event);
    }

    void end(BridgeEvent event) {
      emit(event);
      ended = true;
    }

    final threadId = _host.nextId;
    final runId = _host.nextId;
    emit(BridgeRunStarted(threadId: threadId, runId: runId));

    final printed = CollectString();
    try {
      end(
        await _feed(code, inputs, os, cancelToken, (
          printed,
          threadId,
          runId,
          cwd,
        ), emit),
      );
    } on MontyError catch (e) {
      end(_pythonError(logger, e, printed));
    } on Object catch (e, st) {
      end(_infrastructureError(logger, e, st, printed));
    }
  }

  Future<BridgeRunFinished> _feed(
    String code,
    Map<String, MontyValue>? inputs,
    OsHandler? os,
    CancelToken? cancelToken,
    (CollectString, String, String, String?) run,
    void Function(BridgeEvent) emit,
  ) async {
    final (printed, threadId, runId, cwd) = run;
    final value = await session.feedRun(
      code,
      cwd: cwd,
      inputs: inputs,
      externalLookup: _host.externals(
        emit,
        os: os,
        cancelToken: cancelToken,
      ),
      printCallback: printed.call,
      os: os == null ? null : _OsReporter(_host, logger, emit)._wrap(os),
    );

    return BridgeRunFinished(
      threadId: threadId,
      runId: runId,
      value: value.dartValue,
      montyValue: value,
      printOutput: _printed(printed),
    );
  }
}

/// Logs a Python failure and preserves its structured exception on the event.
BridgeRunError _pythonError(
  BridgeLogger logger,
  MontyError error,
  CollectString printed,
) {
  final message = _composeMessage(
    error.exception.excType,
    error.exception.message ?? '',
  );
  logger.warning('Python error', attributes: {'error': message});

  return BridgeRunError(
    message: message,
    printOutput: _printed(printed),
    exception: error,
  );
}

/// Applies extension wrappers before feeding, releasing the run on failure.
Stream<BridgeEvent> _wrapStream(
  String code,
  StreamController<BridgeEvent> controller,
  List<Stream<BridgeEvent> Function(String, Stream<BridgeEvent>)> wrappers,
  void Function() release,
) {
  var stream = controller.stream;
  try {
    for (final wrap in wrappers) {
      stream = wrap(code, stream);
    }
  } on Object {
    release();
    unawaited(controller.close());
    rethrow;
  }

  return stream;
}

/// Logs lifecycle, tool and OS events at their established levels.
void _logEvent(BridgeLogger logger, BridgeEvent event) {
  if (event case BridgeRunError(:final message, :final exception)) {
    logger.warning(
      'run error',
      attributes: {'message': message},
      error: exception,
    );

    return;
  }
  final entry = switch (event) {
    BridgeRunStarted(:final threadId, :final runId) => (
      logger.info,
      'run started',
      {'threadId': threadId, 'runId': runId},
    ),
    BridgeRunFinished(:final threadId, :final runId) => (
      logger.info,
      'run finished',
      {'threadId': threadId, 'runId': runId},
    ),
    BridgeFunctionCallStart(:final callId, :final name) => (
      logger.debug,
      'tool call',
      {'callId': callId, 'name': name},
    ),
    BridgeFunctionCallResult(:final callId) => (
      logger.debug,
      'tool result',
      {'callId': callId},
    ),
    BridgeOsCallStart(:final callId, :final operationName) => (
      logger.trace,
      'os call',
      {'callId': callId, 'op': operationName},
    ),
    BridgeOsCallResult(:final callId, :final durationMs) => (
      logger.trace,
      'os result',
      {'callId': callId, 'durationMs': ?durationMs},
    ),
    _ => null,
  };
  if (entry != null) entry.$1(entry.$2, attributes: entry.$3);
}

/// Reports OS calls while preserving synchronous answers and declines.
final class _OsReporter {
  const _OsReporter(this._host, this._logger, this._emit);

  final HostDispatch _host;
  final BridgeLogger _logger;
  final void Function(BridgeEvent) _emit;

  OsHandler _wrap(OsHandler handler) => (name, args, kwargs) {
    final callId = _host.nextId;
    _emit(
      BridgeOsCallStart(
        callId: callId,
        operationName: name,
        argumentSummary: args.isEmpty
            ? null
            : args.map((a) => a.dartValue).join(', '),
      ),
    );
    final report = _OsCallReport(callId, name, _logger, _emit);
    final FutureOr<MontyValue> result;
    try {
      result = handler(name, args, kwargs);
    } on OsCallNotHandledException {
      report._result('Declined');
      rethrow;
    } on Object catch (e, st) {
      report._fail(e, st);
    }

    return result is Future<MontyValue>
        ? report._settle(result)
        : report._answer(result);
  };
}

/// Timing and terminal events for a single OS invocation.
final class _OsCallReport {
  _OsCallReport(this._callId, this._name, this._logger, this._emit);

  final String _callId;
  final String _name;
  final BridgeLogger _logger;
  final void Function(BridgeEvent) _emit;
  final Stopwatch _watch = Stopwatch()..start();

  void _result(String text) {
    _watch.stop();
    _emit(
      BridgeOsCallResult(
        callId: _callId,
        result: text,
        durationMs: _watch.elapsedMilliseconds,
      ),
    );
  }

  Never _fail(Object error, StackTrace stackTrace) {
    _logger.error(
      'OS call handler error',
      error: error,
      stackTrace: stackTrace,
      attributes: {'op': _name},
    );
    _result(switch (error) {
      ExternalException(:final message) => 'Error: ${message ?? ''}',
      _ => 'Error: $error',
    });
    Error.throwWithStackTrace(error, stackTrace);
  }

  MontyValue _answer(MontyValue value) {
    _result(value.dartValue?.toString() ?? '');

    return value;
  }

  Future<MontyValue> _settle(Future<MontyValue> pending) async {
    final MontyValue value;
    try {
      value = await pending;
    } on Object catch (e, st) {
      _fail(e, st);
    }

    return _answer(value);
  }
}

BridgeRunError _infrastructureError(
  BridgeLogger logger,
  Object e,
  StackTrace st,
  CollectString printed,
) {
  logger.error('Bridge infrastructure error', error: e, stackTrace: st);
  final event = BridgeRunError(message: '$e', printOutput: _printed(printed));
  recordRunFailure(event, e, st);

  return event;
}
