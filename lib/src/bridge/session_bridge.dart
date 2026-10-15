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
    BridgeLogger? logger,
    MontyRuntimeRef? runtime,
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
  void setOsHandler(OsHandler? handler) {
    if (_isDisposed) return;
    _currentOsHandler = handler;
    _host.osHandler = handler;
  }

  /// The currently-registered OS handler, if any.
  @internal
  OsHandler? get currentOsHandler => _currentOsHandler;

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
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
    var stream = controller.stream;
    try {
      for (final wrap in _streamWrappers) {
        stream = wrap(code, stream);
      }
    } on Object {
      release();
      unawaited(controller.close());
      rethrow;
    }

    unawaited(
      _run(
        code,
        controller,
        inputs: inputs,
        os: os ?? _currentOsHandler,
        cancelToken: cancelToken,
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
  }) async {
    var ended = false;
    void emit(BridgeEvent event) {
      if (ended) return;
      _logEvent(event);
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
      final value = await session.feedRun(
        code,
        inputs: inputs,
        externalLookup: _host.externals(
          emit,
          os: os,
          cancelToken: cancelToken,
        ),
        printCallback: printed.call,
        os: os == null ? null : _reportingOs(os, emit),
      );
      end(
        BridgeRunFinished(
          threadId: threadId,
          runId: runId,
          value: value.dartValue,
          montyValue: value,
          printOutput: _printed(printed),
        ),
      );
    } on MontyError catch (e) {
      final message = _composeMessage(
        e.exception.excType,
        e.exception.message ?? '',
      );
      logger.warning('Python error', attributes: {'error': message});
      end(
        BridgeRunError(
          message: message,
          printOutput: _printed(printed),
          exception: e,
        ),
      );
    } on Object catch (e, st) {
      logger.error('Bridge infrastructure error', error: e, stackTrace: st);
      final event = BridgeRunError(
        message: '$e',
        printOutput: _printed(printed),
      );
      recordRunFailure(event, e, st);
      end(event);
    }
  }

  /// [handler] wrapped to report each call it receives: a
  /// [BridgeOsCallStart], then a [BridgeOsCallResult] with the same call id
  /// when the answer is known.
  ///
  /// A synchronous throw stays synchronous, so a decline
  /// ([OsCallNotHandledException]) still declines; it is reported as
  /// `'Declined'`. A synchronous answer stays synchronous too.
  OsHandler _reportingOs(OsHandler handler, void Function(BridgeEvent) emit) {
    return (name, args, kwargs) {
      final callId = _host.nextId;
      emit(
        BridgeOsCallStart(
          callId: callId,
          operationName: name,
          argumentSummary: args.isEmpty
              ? null
              : args.map((a) => a.dartValue).join(', '),
        ),
      );
      final sw = Stopwatch()..start();
      void report(String result) {
        sw.stop();
        emit(
          BridgeOsCallResult(
            callId: callId,
            result: result,
            durationMs: sw.elapsedMilliseconds,
          ),
        );
      }

      Never fail(Object error, StackTrace stackTrace) {
        logger.error(
          'OS call handler error',
          error: error,
          stackTrace: stackTrace,
          attributes: {'op': name},
        );
        report(switch (error) {
          ExternalException(:final message) => 'Error: ${message ?? ''}',
          _ => 'Error: $error',
        });
        Error.throwWithStackTrace(error, stackTrace);
      }

      MontyValue answer(MontyValue value) {
        report(value.dartValue?.toString() ?? '');

        return value;
      }

      final FutureOr<MontyValue> result;
      try {
        result = handler(name, args, kwargs);
      } on OsCallNotHandledException {
        report('Declined');
        rethrow;
      } on Object catch (e, st) {
        fail(e, st);
      }

      // Only the handler's own failure is reported as an error.
      Future<MontyValue> settle(Future<MontyValue> pending) async {
        final MontyValue value;
        try {
          value = await pending;
        } on Object catch (e, st) {
          fail(e, st);
        }

        return answer(value);
      }

      return result is Future<MontyValue> ? settle(result) : answer(result);
    };
  }

  /// Maps [BridgeEvent]s to [BridgeLogger] calls, so a consumer tailing the
  /// logger sees the execution without subscribing to the stream: trace for
  /// OS calls, debug for host-function calls, info for the run lifecycle,
  /// warning for run errors.
  void _logEvent(BridgeEvent event) {
    switch (event) {
      case BridgeRunStarted(:final threadId, :final runId):
        logger.info(
          'run started',
          attributes: {'threadId': threadId, 'runId': runId},
        );
      case BridgeRunFinished(:final threadId, :final runId):
        logger.info(
          'run finished',
          attributes: {'threadId': threadId, 'runId': runId},
        );
      case BridgeRunError(:final message, :final exception):
        logger.warning(
          'run error',
          attributes: {'message': message},
          error: exception,
        );
      case BridgeFunctionCallStart(:final callId, :final name):
        logger.debug(
          'tool call',
          attributes: {'callId': callId, 'name': name},
        );
      case BridgeFunctionCallResult(:final callId):
        logger.debug('tool result', attributes: {'callId': callId});
      case BridgeOsCallStart(:final callId, :final operationName):
        logger.trace(
          'os call',
          attributes: {'callId': callId, 'op': operationName},
        );
      case BridgeOsCallResult(:final callId, :final durationMs):
        logger.trace(
          'os result',
          attributes: {'callId': callId, 'durationMs': ?durationMs},
        );
      case BridgeCallStarted() ||
          BridgeCallFinished() ||
          BridgeFunctionCallArgs() ||
          BridgeFunctionCallEnd() ||
          BridgeFunctionEmit() ||
          BridgeChildEvent():
        // Step boundaries, argument deltas, emissions and child events:
        // logging them would duplicate the stream.
        break;
    }
  }
}
