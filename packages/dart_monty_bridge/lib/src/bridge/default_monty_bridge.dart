import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_bridge/src/bridge/bridge_event.dart';
import 'package:dart_monty_bridge/src/bridge/host_function.dart';
import 'package:dart_monty_bridge/src/bridge/host_function_schema.dart';
import 'package:dart_monty_bridge/src/bridge/monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
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

const _consoleWriteFn = '__console_write__';

/// Tracks an in-flight host function future awaiting resolution.
class _PendingFuture {
  _PendingFuture({
    required this.future,
    required this.bridgeCallId,
    required this.stepName,
  });

  final Future<Object?> future;
  final String bridgeCallId;
  final String stepName;
}

/// Default [MontyBridge] implementation.
///
/// Orchestrates the Monty start/resume loop, dispatching external function
/// calls to registered [HostFunction] handlers and emitting [BridgeEvent]s.
class DefaultMontyBridge implements MontyBridge {
  /// Creates a [DefaultMontyBridge].
  ///
  /// Pass [logger] to inject a custom logger for this bridge instance.
  /// If omitted, uses the global [LogManager] singleton.
  DefaultMontyBridge({
    MontyPlatform? platform,
    MontyLimits? limits,
    bool useFutures = true,
    Logger? logger,
  }) : _explicitPlatform = platform,
       _limits = limits,
       _useFutures = useFutures,
       log = logger ?? LogManager.instance.getLogger('MontyBridge');

  final MontyPlatform? _explicitPlatform;
  final MontyLimits? _limits;
  final bool _useFutures;

  /// Logger for this bridge instance.
  @protected
  final Logger log;

  final Map<String, HostFunction> _functions = {};
  final Map<int, _PendingFuture> _pendingFutures = {};
  int _idCounter = 0;
  bool _isExecuting = false;
  bool _isDisposed = false;

  MontyPlatform get _platform => _explicitPlatform ?? MontyPlatform.instance;

  String get _nextId => '${_idCounter++}';

  @override
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  @override
  void register(HostFunction function) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _functions[function.schema.name] = function;
  }

  @override
  void unregister(String name) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _functions.remove(name);
  }

  @override
  Stream<BridgeEvent> execute(String code) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    if (_isExecuting) {
      throw StateError('Bridge is already executing');
    }
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
  }

  Future<void> _run(
    String code,
    StreamController<BridgeEvent> controller,
  ) async {
    final threadId = _nextId;
    final runId = _nextId;

    controller.add(BridgeRunStarted(threadId: threadId, runId: runId));

    final printBuffer = StringBuffer();
    final wrappedCode = '$_printPreamble\n$code';
    final externalFunctions = [_consoleWriteFn, ..._functions.keys];
    final futuresCapable = _useFutures && _platform is MontyFutureCapable;

    _pendingFutures.clear();

    try {
      var progress = await _platform.start(
        wrappedCode,
        externalFunctions: externalFunctions,
        limits: _limits,
      );

      while (true) {
        switch (progress) {
          case final MontyPending pending:
            progress = await _handlePending(
              pending,
              printBuffer,
              controller,
              futuresCapable: futuresCapable,
            );

          case final MontyResolveFutures resolve:
            if (futuresCapable && _pendingFutures.isNotEmpty) {
              progress = await _resolveFutures(resolve, controller);
            } else {
              progress = await _platform.resume(null);
            }

          case MontyComplete(:final result):
            _flushPrintBuffer(printBuffer, controller);

            if (result.isError) {
              controller.add(BridgeRunError(message: result.error!.message));
            } else {
              controller.add(
                BridgeRunFinished(
                  threadId: threadId,
                  runId: runId,
                  value: result.value,
                  printOutput: result.printOutput,
                ),
              );
            }
            return;
        }
      }
    } on MontyException catch (e) {
      log.warning('Python error', attributes: {'error': e.message});
      _flushPrintBuffer(printBuffer, controller);
      controller.add(BridgeRunError(message: e.message));
    } on Object catch (e, st) {
      log.error('Bridge infrastructure error', error: e, stackTrace: st);
      _flushPrintBuffer(printBuffer, controller);
      controller.add(BridgeRunError(message: '$e'));
    } finally {
      _pendingFutures.clear();
    }
  }

  Future<MontyProgress> _handlePending(
    MontyPending pending,
    StringBuffer printBuffer,
    StreamController<BridgeEvent> controller, {
    required bool futuresCapable,
  }) async {
    final name = pending.functionName;

    // Console write — always intercept, buffer for text flush.
    if (name == _consoleWriteFn) {
      if (pending.arguments.isNotEmpty) {
        printBuffer.write(pending.arguments.first.toString());
      }

      return _platform.resume(null);
    }

    // Registered host function — emit tool call events.
    final fn = _functions[name];
    if (fn != null) {
      log.trace('Host function call', attributes: {'name': name});
      if (futuresCapable) {
        return _dispatchToolCallAsFuture(fn, pending, controller);
      }
      return _dispatchToolCall(fn, pending, controller);
    }

    // Unknown function — raise error in Python.
    log.warning('Unknown function', attributes: {'name': name});
    return _platform.resumeWithError('Unknown function: $name');
  }

  Future<MontyProgress> _dispatchToolCall(
    HostFunction fn,
    MontyPending pending,
    StreamController<BridgeEvent> controller,
  ) async {
    final callId = _nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeStepStarted(stepId: stepName))
      ..add(BridgeToolCallStart(callId: callId, name: stepName));

    // Map and validate arguments.
    final Map<String, Object?> args;
    try {
      args = fn.schema.mapAndValidate(pending);
    } on FormatException catch (e) {
      log.warning(
        'Argument validation failed',
        attributes: {'function': stepName, 'error': e.message},
      );
      controller
        ..add(BridgeToolCallResult(callId: callId, result: 'Error: $e'))
        ..add(BridgeStepFinished(stepId: stepName));

      return _platform.resumeWithError(e.toString());
    }
    controller
      ..add(BridgeToolCallArgs(callId: callId, delta: jsonEncode(args)))
      ..add(BridgeToolCallEnd(callId: callId));

    // Execute handler.
    try {
      final result = await fn.handler(args);
      controller
        ..add(
          BridgeToolCallResult(
            callId: callId,
            result: result?.toString() ?? '',
          ),
        )
        ..add(BridgeStepFinished(stepId: stepName));

      return _platform.resume(result);
    } on Object catch (e, st) {
      log.error(
        'Host handler error',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );
      controller
        ..add(BridgeToolCallResult(callId: callId, result: 'Error: $e'))
        ..add(BridgeStepFinished(stepId: stepName));

      return _platform.resumeWithError(e.toString());
    }
  }

  Future<MontyProgress> _dispatchToolCallAsFuture(
    HostFunction fn,
    MontyPending pending,
    StreamController<BridgeEvent> controller,
  ) async {
    final callId = _nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeStepStarted(stepId: stepName))
      ..add(BridgeToolCallStart(callId: callId, name: stepName));

    // Map and validate arguments.
    final Map<String, Object?> args;
    try {
      args = fn.schema.mapAndValidate(pending);
    } on FormatException catch (e) {
      controller
        ..add(BridgeToolCallResult(callId: callId, result: 'Error: $e'))
        ..add(BridgeStepFinished(stepId: stepName));

      return _platform.resumeWithError(e.toString());
    }
    controller
      ..add(BridgeToolCallArgs(callId: callId, delta: jsonEncode(args)))
      ..add(BridgeToolCallEnd(callId: callId));

    // Launch handler and store future for later resolution.
    // Errors are caught during resolution in _resolveFutures; suppress
    // unhandled async error reporting in the meantime.
    final handlerFuture = fn.handler(args);
    unawaited(handlerFuture.then<void>((_) {}, onError: (_, __) {}));
    _pendingFutures[pending.callId] = _PendingFuture(
      future: handlerFuture,
      bridgeCallId: callId,
      stepName: stepName,
    );

    return (_platform as MontyFutureCapable).resumeAsFuture();
  }

  Future<MontyProgress> _resolveFutures(
    MontyResolveFutures resolve,
    StreamController<BridgeEvent> controller,
  ) async {
    final results = <int, Object?>{};
    final errors = <int, String>{};

    // Collect futures for the requested call IDs.
    final entries = <int, _PendingFuture>{};
    for (final id in resolve.pendingCallIds) {
      final pending = _pendingFutures.remove(id);
      if (pending != null) entries[id] = pending;
    }

    // Await all futures and partition into results/errors.
    for (final entry in entries.entries) {
      final id = entry.key;
      final pending = entry.value;
      try {
        final value = await pending.future;
        results[id] = value;
        controller
          ..add(
            BridgeToolCallResult(
              callId: pending.bridgeCallId,
              result: value?.toString() ?? '',
            ),
          )
          ..add(BridgeStepFinished(stepId: pending.stepName));
      } on Object catch (e) {
        errors[id] = e.toString();
        controller
          ..add(
            BridgeToolCallResult(
              callId: pending.bridgeCallId,
              result: 'Error: $e',
            ),
          )
          ..add(BridgeStepFinished(stepId: pending.stepName));
      }
    }

    return (_platform as MontyFutureCapable).resolveFutures(
      results,
      errors: errors.isEmpty ? null : errors,
    );
  }

  void _flushPrintBuffer(
    StringBuffer buffer,
    StreamController<BridgeEvent> controller,
  ) {
    if (buffer.isEmpty) return;
    final messageId = _nextId;
    controller
      ..add(BridgeTextStart(messageId: messageId))
      ..add(BridgeTextContent(messageId: messageId, delta: buffer.toString()))
      ..add(BridgeTextEnd(messageId: messageId));
  }
}
