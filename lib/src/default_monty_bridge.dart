import 'dart:async';

import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/bridge_logger.dart';
import 'package:dart_monty/src/bridge_middleware.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/monty_bridge.dart';
import 'package:dart_monty/src/plugin_host.dart';
import 'package:dart_monty/src/struct_log_bridge_logger.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';
import 'package:struct_log/struct_log.dart';

// ---------------------------------------------------------------------------
// Top-level helpers — pure utilities that do not need bridge instance state.
// ---------------------------------------------------------------------------

/// Handles the [MontyComplete] terminal step — emits [BridgeRunFinished] or
/// [BridgeRunError] depending on the result.
///
/// `printOutput` is sourced directly from [MontyResult.printOutput] — the
/// Monty interpreter captures `print()` output natively.
void _emitComplete(
  MontyComplete complete,
  StreamController<BridgeEvent> controller,
  String threadId,
  String runId,
) {
  if (complete.result.isError) {
    final e = complete.result.error!;
    controller.add(
      BridgeRunError(
        message: e.message,
        printOutput: complete.result.printOutput,
        exception: e,
      ),
    );
  } else {
    controller.add(
      BridgeRunFinished(
        threadId: threadId,
        runId: runId,
        value: complete.result.value.dartValue,
        printOutput: complete.result.printOutput,
      ),
    );
  }
}

/// Emits a [BridgeRunError] for a [MontyScriptError] caught during `_run`.
void _emitScriptError(
  MontyScriptError e,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
) {
  final msg = e.exception?.message ?? e.message;
  log.warning('Python error', attributes: {'error': msg});
  controller.add(BridgeRunError(message: msg, exception: e.exception));
}

/// Emits a [BridgeRunError] for a [MontyError] caught during `_run`.
void _emitMontyError(
  MontyError e,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
) {
  log.warning('Monty error', attributes: {'error': e.message});
  controller.add(BridgeRunError(message: e.message));
}

/// Emits a [BridgeRunError] for an unexpected [Object] caught during `_run`.
void _emitInfraError(
  Object e,
  StackTrace stackTrace,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
) {
  log.error('Bridge infrastructure error', error: e, stackTrace: stackTrace);
  controller.add(BridgeRunError(message: '$e'));
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
       log = logger ?? StructLogBridgeLogger.root(LogManager.instance),
       _host = PluginHost(
         platform: platform,
         log: logger ?? StructLogBridgeLogger.root(LogManager.instance),
       );

  /// Logger for this bridge instance.
  @protected
  final BridgeLogger log;

  final MontyPlatform _platform;
  final MontyLimits? _limits;
  final bool _useFutures;
  final PluginHost _host;

  OsCallHandler? _osHandler;

  bool _isExecuting = false;
  bool _isDisposed = false;

  // Stream wrappers registered by PluginRegistry for plugins that override
  // wrapExecuteStream. Applied in registration order (first = outermost).
  final List<Stream<BridgeEvent> Function(String, Stream<BridgeEvent>)>
  _streamWrappers = [];

  /// Registers a stream wrapper callback from a plugin.
  ///
  /// Called by `PluginRegistry` during `PluginRegistry.attachTo` for each
  /// plugin whose `MontyPlugin.hasStreamWrapper` returns `true`.
  @internal
  void addStreamWrapper(
    Stream<BridgeEvent> Function(String code, Stream<BridgeEvent> stream)
    wrapper,
  ) {
    _streamWrappers.add(wrapper);
  }

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
  void registerOs(OsCallHandler handler) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _osHandler = handler;
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

    // Apply plugin stream wrappers in registration order.
    // If any wrapper throws synchronously, reset _isExecuting so the bridge
    // is not permanently locked and re-throw.
    // Note: do NOT close the controller here — _run is already running via
    // unawaited and will close it via its own whenComplete. Closing it early
    // causes _run to throw when it tries controller.add(), producing an
    // unhandled zone error.
    try {
      var stream = controller.stream.map((event) {
        _logEvent(event);

        return event;
      });
      for (final wrap in _streamWrappers) {
        stream = wrap(code, stream);
      }

      return stream;
    } catch (_) {
      _isExecuting = false;
      rethrow;
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _osHandler = null;
    log.close();
  }

  // ---------------------------------------------------------------------------
  // Internal execution loop.
  // ---------------------------------------------------------------------------

  /// Dispatches a [MontyOsCall] through the registered [OsCallHandler],
  /// emitting `BridgeOsCallStart`/`BridgeOsCallResult` and resuming the
  /// platform. Errors are surfaced via `resumeWithError`.
  ///
  /// Mirrors the shape of `MontyRepl._handleOsCall` — arguments and kwargs
  /// are unwrapped to raw `Object?` values before invoking the handler.
  Future<MontyProgress> _handleOsCall(
    MontyOsCall osCall,
    StreamController<BridgeEvent> controller,
  ) async {
    final callId = _host.nextId;
    final opName = osCall.operationName;
    final argSummary = osCall.arguments.isEmpty
        ? null
        : osCall.arguments.map((a) => a.dartValue).join(', ');

    controller.add(
      BridgeOsCallStart(
        callId: callId,
        operationName: opName,
        argumentSummary: argSummary,
      ),
    );

    final handler = _osHandler;
    if (handler == null) {
      log.warning('OS call denied (no handler)', attributes: {'op': opName});
      final errorMsg =
          'PermissionError: $opName not available (no filesystem configured)';
      controller.add(BridgeOsCallResult(callId: callId, result: errorMsg));

      return _platform.resumeWithError(errorMsg);
    }

    final sw = Stopwatch()..start();
    try {
      final args = osCall.arguments.map((v) => v.dartValue).toList();
      final kwargs = osCall.kwargs?.map((k, v) => MapEntry(k, v.dartValue));
      final result = await handler(opName, args, kwargs);
      sw.stop();
      controller.add(
        BridgeOsCallResult(
          callId: callId,
          result: result?.toString() ?? '',
          durationMs: sw.elapsedMilliseconds,
        ),
      );

      return await _platform.resume(result);
    } on Object catch (e, st) {
      sw.stop();
      log.error(
        'OS call handler error',
        error: e,
        stackTrace: st,
        attributes: {'op': opName},
      );
      controller.add(
        BridgeOsCallResult(
          callId: callId,
          result: 'Error: $e',
          durationMs: sw.elapsedMilliseconds,
        ),
      );

      return _platform.resumeWithError(e.toString());
    }
  }

  /// Drives the Monty start/resume loop, mirroring the shape of
  /// `MontyRepl._driveLoop`. Each [MontyProgress] kind is handled inline;
  /// the switch terminates on [MontyComplete] after emitting the terminal
  /// [BridgeRunFinished] / [BridgeRunError] event.
  Future<void> _run(
    String code,
    StreamController<BridgeEvent> controller,
  ) async {
    final threadId = _host.nextId;
    final runId = _host.nextId;
    controller.add(BridgeRunStarted(threadId: threadId, runId: runId));

    final externalFunctions = _host.schemas.map((s) => s.name).toList();
    final futuresCapable = _useFutures && _platform is MontyFutureCapable;
    _host.clearPendingFutures();

    try {
      var progress = await _platform.start(
        code,
        externalFunctions: externalFunctions,
        limits: _limits,
      );
      while (true) {
        switch (progress) {
          case final MontyComplete complete:
            _emitComplete(complete, controller, threadId, runId);

            return;
          case final MontyPending pending:
            progress = await _host.handlePending(
              pending,
              controller,
              futuresCapable: futuresCapable,
            );
          case final MontyOsCall osCall:
            progress = await _handleOsCall(osCall, controller);
          case final MontyResolveFutures resolve:
            progress = await (futuresCapable
                ? _host.resolveFutures(resolve, controller)
                : _platform.resume(null));
          case final MontyNameLookup lookup:
            // The bridge does not maintain a name-constant registry.
            // Indicate undefined so Python raises NameError.
            progress = await _platform.resumeNameLookupUndefined(
              lookup.variableName,
            );
        }
      }
    } on MontyScriptError catch (e) {
      _emitScriptError(e, controller, log);
    } on MontyError catch (e) {
      _emitMontyError(e, controller, log);
    } on Object catch (e, st) {
      _emitInfraError(e, st, controller, log);
    } finally {
      _host.clearPendingFutures();
    }
  }

  /// Maps [BridgeEvent]s to [BridgeLogger] calls so consumers that tail the
  /// logger see a complete execution trace without also subscribing to the
  /// event stream.
  ///
  /// Trace level is used for OS calls (high-volume, verbose); debug for tool
  /// calls; info for run lifecycle; warning for run errors.
  void _logEvent(BridgeEvent event) {
    switch (event) {
      case BridgeRunStarted(:final threadId, :final runId):
        log.info(
          'run started',
          attributes: {'threadId': threadId, 'runId': runId},
        );
      case BridgeRunFinished(:final threadId, :final runId):
        log.info(
          'run finished',
          attributes: {'threadId': threadId, 'runId': runId},
        );
      case BridgeRunError(:final message, :final exception):
        log.warning(
          'run error',
          attributes: {'message': message},
          error: exception,
        );
      case BridgeToolCallStart(:final callId, :final name):
        log.debug('tool call', attributes: {'callId': callId, 'name': name});
      case BridgeToolCallResult(:final callId):
        log.debug('tool result', attributes: {'callId': callId});
      case BridgeOsCallStart(:final callId, :final operationName):
        log.trace(
          'os call',
          attributes: {'callId': callId, 'op': operationName},
        );
      case BridgeOsCallResult(:final callId, :final durationMs):
        log.trace(
          'os result',
          attributes: {'callId': callId, 'durationMs': ?durationMs},
        );
      case BridgeStepStarted() ||
          BridgeStepFinished() ||
          BridgeToolCallArgs() ||
          BridgeToolCallEnd():
        // No-op: these events are surface-level telemetry (step boundaries,
        // argument deltas) — logging them would be chatty duplication of
        // the event stream.
        break;
    }
  }
}
