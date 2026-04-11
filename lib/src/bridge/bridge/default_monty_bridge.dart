import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
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
import 'package:dart_monty/src/platform/monty_value.dart';
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

const _consoleWriteFn = '__console_write__';
const _roleKwarg = '__role__';

/// Tracks an in-flight host function future awaiting resolution.
class _PendingFuture {
  const _PendingFuture({
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
       log = logger ?? StructLogBridgeLogger.root(LogManager.instance);

  /// Logger for this bridge instance.
  @protected
  final BridgeLogger log;

  final MontyPlatform _platform;
  final MontyLimits? _limits;
  final bool _useFutures;
  final Map<String, HostFunction> _functions = {};
  final List<BridgeMiddleware> _middleware = [];
  final Map<int, _PendingFuture> _pendingFutures = {};
  int _idCounter = 0;
  bool _isExecuting = false;
  bool _isDisposed = false;
  OsProvider? _osProvider;

  @override
  BridgeLogger get logger => log;

  String get _nextId => '${_idCounter++}';

  @override
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  @override
  void use(BridgeMiddleware middleware) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _middleware.add(middleware);
  }

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
  void registerOs(OsProvider provider) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _osProvider = provider;
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
    unawaited(_osProvider?.dispose());
    log.close();
  }

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    CallRole role = const ToolCall(),
  }) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    final fn = _functions[name];
    if (fn == null) {
      throw ArgumentError('Unknown host function: $name');
    }

    // Route through mapAndValidate for type coercion (e.g., string→int).
    // Construct a MontyPending with kwargs only (Dart callers use named args).
    // Wrap raw Dart values as MontyValue so they satisfy the typed constructor.
    final pending = MontyPending(
      functionName: name,
      arguments: const [],
      kwargs: args.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
    );
    final validatedArgs = fn.schema.mapAndValidate(pending);

    return _invokeWithMiddleware(fn, name, validatedArgs, role);
  }

  /// Initialises a single execution: builds preamble, starts the platform,
  /// and emits [BridgeRunStarted].
  ///
  /// Returns the initial [MontyProgress], a shared [StringBuffer] for print
  /// output, the thread/run IDs, and whether the platform supports futures.
  Future<
    ({
      MontyProgress progress,
      String threadId,
      String runId,
      bool futuresCapable,
    })
  >
  _initExecution(String code, StreamController<BridgeEvent> controller) async {
    final threadId = _nextId;
    final runId = _nextId;
    controller.add(BridgeRunStarted(threadId: threadId, runId: runId));

    final wrappedCode = '$_printPreamble\n$code';
    final externalFunctions = [_consoleWriteFn, ..._functions.keys];
    final futuresCapable = _useFutures && _platform is MontyFutureCapable;
    _pendingFutures.clear();

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

  /// Dispatches a single [MontyProgress] step.
  ///
  /// Returns the next [MontyProgress] to continue the loop, or `null` when
  /// execution is complete (i.e. [MontyComplete] was handled).
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
        return _handlePending(
          pending,
          printBuffer,
          controller,
          futuresCapable: futuresCapable,
        );
      case final MontyOsCall osCall:
        return _handleOsCall(osCall, controller);
      case final MontyResolveFutures resolve:
        return (futuresCapable && _pendingFutures.isNotEmpty)
            ? _resolveFutures(resolve, controller)
            : _platform.resume(null);
      case MontyComplete(:final result):
        _flushPrintBuffer(printBuffer, controller);
        final capturedOutput = printBuffer.isNotEmpty
            ? printBuffer.toString()
            : result.printOutput;
        if (result.isError) {
          final adjusted = _adjustException(result.error!);
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
              value: result.value?.dartValue,
              printOutput: capturedOutput,
            ),
          );
        }

        return null;
    }
  }

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
      final adjusted = e.exception != null
          ? _adjustException(e.exception!)
          : null;
      log.warning(
        'Python error',
        attributes: {'error': adjusted?.message ?? e.message},
      );
      _flushPrintBuffer(printBuffer, controller);
      final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
      controller.add(
        BridgeRunError(
          message: adjusted?.message ?? e.message,
          printOutput: output,
          exception: adjusted,
        ),
      );
    } on MontyError catch (e) {
      log.warning('Monty error', attributes: {'error': e.message});
      _flushPrintBuffer(printBuffer, controller);
      final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
      controller.add(BridgeRunError(message: e.message, printOutput: output));
    } on Object catch (e, st) {
      log.error('Bridge infrastructure error', error: e, stackTrace: st);
      _flushPrintBuffer(printBuffer, controller);
      final output = printBuffer.isNotEmpty ? printBuffer.toString() : null;
      controller.add(BridgeRunError(message: '$e', printOutput: output));
    } finally {
      _pendingFutures.clear();
    }
  }

  Future<MontyProgress> _handlePending(
    MontyPending pending,
    StringBuffer printBuffer,
    StreamController<BridgeEvent> controller, {
    required bool futuresCapable,
  }) {
    final name = pending.functionName;

    // Console write — always intercept, buffer for text flush.
    if (name == _consoleWriteFn) {
      if (pending.arguments.isNotEmpty) {
        printBuffer.write(pending.arguments.first.dartValue?.toString());
      }

      return _platform.resume(null);
    }

    // Registered host function — extract role, strip reserved kwargs, dispatch.
    final fn = _functions[name];
    if (fn != null) {
      final (cleanedPending, role) = _extractRole(pending, fn.role);
      log.trace('Host function call', attributes: {'name': name});
      if (futuresCapable) {
        return _dispatchToolCallAsFuture(
          fn,
          cleanedPending,
          controller,
          role: role,
        );
      }

      return _dispatchToolCall(fn, cleanedPending, controller, role: role);
    }

    // Unknown function — raise error in Python.
    log.warning('Unknown function', attributes: {'name': name});

    return _platform.resumeWithError('Unknown function: $name');
  }

  Future<MontyProgress> _handleOsCall(
    MontyOsCall osCall,
    StreamController<BridgeEvent> controller,
  ) async {
    final callId = _nextId;
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

    final handler = _osProvider;
    if (handler == null) {
      log.warning('OS call denied (no handler)', attributes: {'op': opName});
      final errorMsg =
          'PermissionError: $opName not available (no filesystem configured)';
      controller.add(BridgeOsCallResult(callId: callId, result: errorMsg));

      return _platform.resumeWithError(errorMsg);
    }

    final sw = Stopwatch()..start();
    try {
      final result = await handler.resolve(osCall);
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

  /// Resolves the [CallRole] for a tool call and strips the reserved
  /// `__role__` kwarg from [pending].
  ///
  /// Resolution order:
  /// 1. If [hostRole] is non-null (declared on [HostFunction]), it is
  ///    authoritative — Python cannot override it.
  /// 2. Otherwise, the `__role__` kwarg from Python is used.
  /// 3. If neither is present, defaults to [ToolCall].
  (MontyPending, CallRole) _extractRole(
    MontyPending pending,
    CallRole? hostRole,
  ) {
    final kwargs = pending.kwargs;

    // Always strip __role__ from kwargs regardless of how role is resolved.
    final MontyPending cleanedPending;
    if (kwargs != null && kwargs.containsKey(_roleKwarg)) {
      final cleaned = Map<String, MontyValue>.of(kwargs)..remove(_roleKwarg);
      cleanedPending = MontyPending(
        functionName: pending.functionName,
        arguments: pending.arguments,
        kwargs: cleaned.isEmpty ? null : cleaned,
        callId: pending.callId,
        methodCall: pending.methodCall,
      );
    } else {
      cleanedPending = pending;
    }

    // Host-declared role is authoritative — Python cannot escalate.
    if (hostRole != null) {
      return (cleanedPending, hostRole);
    }

    // Fall back to Python kwarg, defaulting to ToolCall.
    final roleValue = kwargs?[_roleKwarg]?.dartValue;
    final role = switch (roleValue) {
      'infra' => const InfraCall(),
      _ => const ToolCall(),
    };

    return (cleanedPending, role);
  }

  /// Invokes [fn] through the middleware chain with the given [role].
  ///
  /// Fast path: when no middleware is registered, calls the handler directly.
  Future<Object?> _invokeWithMiddleware(
    HostFunction fn,
    String name,
    Map<String, Object?> args,
    CallRole role,
  ) {
    if (_middleware.isEmpty) return fn.handler(args);

    // Build onion chain: first registered = outermost.
    var handler = (String _, Map<String, Object?> a) => fn.handler(a);
    for (final mw in _middleware.reversed) {
      final next = handler;
      handler = (n, a) => mw.handle(n, a, role, next);
    }

    return handler(name, args);
  }

  Future<MontyProgress> _dispatchToolCall(
    HostFunction fn,
    MontyPending pending,
    StreamController<BridgeEvent> controller, {
    required CallRole role,
  }) async {
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

    // Execute handler through middleware chain.
    try {
      final result = await _invokeWithMiddleware(fn, stepName, args, role);
      controller
        ..add(
          BridgeToolCallResult(
            callId: callId,
            result: result?.toString() ?? '',
          ),
        )
        ..add(BridgeStepFinished(stepId: stepName));

      return await _platform.resume(result);
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
    StreamController<BridgeEvent> controller, {
    required CallRole role,
  }) {
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
    //
    // If the handler throws synchronously (before returning a Future),
    // we must catch it here to avoid deadlocking the platform in active
    // state with a leaked FFI handle.
    final Future<Object?> handlerFuture;
    try {
      handlerFuture = _invokeWithMiddleware(fn, stepName, args, role);
    } on Object catch (e, st) {
      log.error(
        'Host handler threw synchronously',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );
      controller
        ..add(BridgeToolCallResult(callId: callId, result: 'Error: $e'))
        ..add(BridgeStepFinished(stepId: stepName));

      return _platform.resumeWithError(e.toString());
    }
    unawaited(
      handlerFuture.then<void>(
        (_) {
          // Success value intentionally ignored — result is consumed during
          // future resolution in _resolveFutures.
        },
        onError: (Object e, StackTrace st) {
          log.warning(
            'Deferred host handler error',
            error: e,
            stackTrace: st,
            attributes: {'function': stepName},
          );
        },
      ),
    );
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

  /// Adjusts [MontyException] line numbers to account for the print preamble
  /// injected by [_run]. Filters out traceback frames from the preamble.
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
