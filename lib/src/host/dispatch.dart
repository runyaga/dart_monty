import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart'
    show DispatchMode, HostFunction;
import 'package:dart_monty/src/host/function_surface.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Intercepts a host function call before the handler runs.
///
/// Called only for non-infra functions. [next] invokes the actual handler.
/// Return a value or throw to short-circuit the handler.
typedef MontyInterceptor =
    Future<Object?> Function(
      String name,
      Map<String, Object?> args,
      Future<Object?> Function() next,
    );

// ---------------------------------------------------------------------------
// Internal tracking for the futures (WASM) dispatch path.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Top-level helpers shared by HostDispatch dispatch methods.
// ---------------------------------------------------------------------------

/// Default [HostSubExecutor] wired into every [HostContext]. Runs [code]
/// in a fresh Monty interpreter via `Monty(code).run()` so host functions
/// can drive sub-executions without contending with the caller's bridge lock.
Future<MontyResult> _defaultSubExecute(
  String code, {
  Map<String, Object?>? inputs,
}) => Monty(code).run(inputs: inputs);

/// Invokes [fn] through [interceptor], or calls the handler directly when
/// [fn] is infra or no interceptor is registered.
Future<Object?> _invoke(
  MontyInterceptor? interceptor,
  HostFunction fn,
  String name,
  Map<String, Object?> args,
  HostContext ctx,
) {
  if (interceptor == null || fn.isInfra) return fn.handler!(args, ctx);

  return interceptor(name, args, () => fn.handler!(args, ctx));
}

/// Validates [pending] arguments against [fn]'s schema and emits the
/// `BridgeFunctionCallArgs`/`BridgeFunctionCallEnd` events on success.
///
/// Returns the validated arg map, or `null` when validation fails (the
/// `BridgeFunctionCallResult`/`BridgeCallFinished` error events are already
/// emitted and the caller must call `resumeWithError`). The `FormatException`
/// message is written to `resumeError` on failure.
///
/// Using a nullable return instead of throwing keeps the caller's flow linear.
Map<String, Object?>? _validateToolCallArgs(
  HostFunction fn,
  MontyPending pending,
  String callId,
  StreamController<BridgeEvent> controller,
  BridgeLogger log,
  void Function(String) setResumeError,
) {
  final Map<String, Object?> args;
  try {
    args = fn.schema.mapAndValidate(pending);
  } on FormatException catch (e) {
    final stepName = pending.functionName;
    log.warning(
      'Argument validation failed',
      attributes: {'function': stepName, 'error': e.message},
    );
    controller
      ..add(BridgeFunctionCallResult(callId: callId, result: 'Error: $e'))
      ..add(BridgeCallFinished(callId: callId));
    setResumeError(e.toString());

    return null;
  }
  controller
    ..add(BridgeFunctionCallArgs(callId: callId, delta: jsonEncode(args)))
    ..add(BridgeFunctionCallEnd(callId: callId));

  return args;
}

/// Emits [BridgeFunctionCallResult] + [BridgeCallFinished] for a handler error
/// and returns `platform.resumeWithError`.
Future<MontyProgress> _emitToolCallError(
  String callId,
  String error,
  StreamController<BridgeEvent> controller,
  MontyPlatform platform,
) {
  controller
    ..add(BridgeFunctionCallResult(callId: callId, result: 'Error: $error'))
    ..add(BridgeCallFinished(callId: callId));

  return platform.resumeWithError(error);
}

/// Suppresses unhandled async errors from [future], logging a warning.
/// Errors surface later during [MontyResolveFutures] resolution.
void _suppressFutureErrors(
  Future<Object?> future,
  String stepName,
  BridgeLogger log,
) {
  unawaited(_logDeferredError(future, stepName, log));
}

Future<void> _logDeferredError(
  Future<Object?> future,
  String stepName,
  BridgeLogger log,
) async {
  try {
    await future;
  } on Object catch (e, st) {
    log.warning(
      'Deferred host handler error',
      error: e,
      stackTrace: st,
      attributes: {'function': stepName},
    );
  }
}

// ---------------------------------------------------------------------------
// HostDispatch — function registry + tool dispatch.
// ---------------------------------------------------------------------------

/// Manages host function registration, the interceptor, and tool call dispatch
/// for a `PlatformBridge`.
///
/// This is an internal implementation-detail class — it is not part of the
/// public `MontyBridge` API. Callers access it through the bridge's delegation
/// methods.
@internal
class HostDispatch {
  /// Creates a [HostDispatch].
  ///
  /// [platform] is required for dispatching resume/resumeWithError calls.
  /// [log] is used for warning/error messages emitted during dispatch.
  HostDispatch({
    required MontyPlatform platform,
    required BridgeLogger log,
    MontyInterceptor? interceptor,
    MontyRuntimeRef? runtime,
  }) : _platform = platform,
       _log = log,
       _interceptor = interceptor,
       _runtime = runtime;

  /// Current OS call handler — mirrored from the owning bridge so handlers
  /// receive it via [HostContext.os]. Updated by the bridge's `registerOs`.
  OsCallHandler? osHandler;

  final MontyPlatform _platform;
  final BridgeLogger _log;
  final MontyInterceptor? _interceptor;
  final MontyRuntimeRef? _runtime;

  final Map<String, HostFunction> _functions = {};
  final Map<String, Set<String>> _categoryIndex = {};

  final Map<int, _PendingFuture> _pendingFutures = {};
  int _idCounter = 0;

  // ---------------------------------------------------------------------------
  // ID generation.
  // ---------------------------------------------------------------------------

  /// Returns a unique string ID, incrementing an internal counter.
  String get nextId => '${_idCounter++}';

  // ---------------------------------------------------------------------------
  // Function registration.
  // ---------------------------------------------------------------------------

  /// All registered function schemas.
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  /// Schemas for functions that declare [FunctionSurface.llm].
  List<HostFunctionSchema> get exposedSchemas => _functions.values
      .where((f) => f.surfaces.contains(FunctionSurface.llm))
      .map((f) => f.schema)
      .toList(growable: false);

  /// All registered function schemas, grouped by category.
  Map<String, List<HostFunctionSchema>> get schemasByCategory {
    final result = <String, List<HostFunctionSchema>>{};
    for (final entry in _categoryIndex.entries) {
      final categorySchemas = <HostFunctionSchema>[];
      for (final name in entry.value) {
        final fn = _functions[name];
        if (fn != null) categorySchemas.add(fn.schema);
      }
      if (categorySchemas.isNotEmpty) result[entry.key] = categorySchemas;
    }

    return result;
  }

  /// Registers [function] under an optional [category].
  ///
  /// Silently skips functions whose [HostFunction.handler] is `null` on the
  /// current backend — no `supportedBackends` declaration required.
  void register(HostFunction function, {String? category}) {
    if (function.handler == null) return;
    final name = function.schema.name;
    _functions[name] = function;
    (_categoryIndex[category ?? 'uncategorized'] ??= {}).add(name);
  }

  /// Unregisters the function with [name].
  void unregister(String name) => _functions.remove(name);

  /// Invokes a registered host function by [name] directly from Dart.
  ///
  /// Infra functions bypass the interceptor; all others go through it.
  ///
  /// When [onEvent] is provided, any [BridgeEvent] the handler emits via
  /// `HostContext.emit` / `HostContext.emitText` is delivered to the callback
  /// before the returned future completes. When [onEvent] is omitted, emissions
  /// are dropped (direct-Dart calls have no stream). Stream wrappers registered
  /// by extensions apply to Python-`execute` runs only and are NOT applied to
  /// direct invocations.
  ///
  /// Callback exceptions are logged via the bridge logger and swallowed.
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    void Function(BridgeEvent)? onEvent,
  }) {
    final fn = _functions[name];
    if (fn == null) throw ArgumentError('Unknown host function: $name');
    final pending = MontyPending(
      functionName: name,
      arguments: const [],
      kwargs: args.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
    );
    final validatedArgs = fn.schema.mapAndValidate(pending);
    void sink(BridgeEvent event) {
      if (onEvent == null) return;
      try {
        onEvent(event);
      } on Object catch (err, st) {
        _log.error(
          'invokeHostFunction onEvent callback threw',
          error: err,
          stackTrace: st,
          attributes: {'name': name},
        );
      }
    }

    final ctx = HostContext(
      emit: sink,
      executionId: name,
      os: osHandler,
      parent: _runtime,
      subExecute: _defaultSubExecute,
    );

    return _invoke(_interceptor, fn, name, validatedArgs, ctx);
  }

  // ---------------------------------------------------------------------------
  // Execution dispatch.
  // ---------------------------------------------------------------------------

  /// Dispatches a [MontyPending] step — routes registered host functions and
  /// unknown functions.
  Future<MontyProgress> handlePending(
    MontyPending pending,
    StreamController<BridgeEvent> controller, {
    required bool futuresCapable,
  }) {
    final name = pending.functionName;

    final fn = _functions[name];
    if (fn != null) {
      _log.trace('Host function call', attributes: {'name': name});

      final useFutureDispatch =
          fn.dispatch == DispatchMode.future && futuresCapable;

      return useFutureDispatch
          ? dispatchToolCallAsFuture(fn, pending, controller)
          : dispatchToolCall(fn, pending, controller);
    }

    _log.warning('Unknown function', attributes: {'name': name});

    return _platform.resumeWithError('Unknown function: $name');
  }

  /// Invokes [fn] synchronously and resumes the platform with the result.
  ///
  /// Handler errors are caught and surfaced via `resumeWithError`. resume()
  /// errors must NOT be caught here — if resume() fails it has already called
  /// markIdle() and a subsequent resumeWithError() would hit a StateError.
  Future<MontyProgress> dispatchToolCall(
    HostFunction fn,
    MontyPending pending,
    StreamController<BridgeEvent> controller,
  ) async {
    final callId = nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeCallStarted(callId: callId))
      ..add(BridgeFunctionCallStart(callId: callId, name: stepName));

    var resumeError = '';
    final args = _validateToolCallArgs(
      fn,
      pending,
      callId,
      controller,
      _log,
      (e) => resumeError = e,
    );
    if (args == null) return _platform.resumeWithError(resumeError);

    final ctx = HostContext(
      emit: controller.add,
      executionId: callId,
      os: osHandler,
      parent: _runtime,
      subExecute: _defaultSubExecute,
    );
    final Object? result;
    try {
      result = await _invoke(_interceptor, fn, stepName, args, ctx);
    } on Object catch (e, st) {
      _log.error(
        'Host handler error',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );

      return _emitToolCallError(callId, '$e', controller, _platform);
    }

    controller
      ..add(
        BridgeFunctionCallResult(
          callId: callId,
          result: result?.toString() ?? '',
        ),
      )
      ..add(BridgeCallFinished(callId: callId));

    return _platform.resume(result);
  }

  /// Launches [fn] as a deferred future and resumes the platform immediately.
  ///
  /// The future is tracked in [_pendingFutures] for resolution during the next
  /// [MontyResolveFutures] step. Synchronous throws are caught and surfaced
  /// immediately to avoid deadlocking the platform with a leaked FFI handle.
  Future<MontyProgress> dispatchToolCallAsFuture(
    HostFunction fn,
    MontyPending pending,
    StreamController<BridgeEvent> controller,
  ) {
    final callId = nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeCallStarted(callId: callId))
      ..add(BridgeFunctionCallStart(callId: callId, name: stepName));

    var resumeError = '';
    final args = _validateToolCallArgs(
      fn,
      pending,
      callId,
      controller,
      _log,
      (e) => resumeError = e,
    );
    if (args == null) return _platform.resumeWithError(resumeError);

    final ctx = HostContext(
      emit: controller.add,
      executionId: callId,
      os: osHandler,
      parent: _runtime,
      subExecute: _defaultSubExecute,
    );
    final Future<Object?> handlerFuture;
    try {
      handlerFuture = _invoke(_interceptor, fn, stepName, args, ctx);
    } on Object catch (e, st) {
      _log.error(
        'Host handler threw synchronously',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );

      return _emitToolCallError(callId, '$e', controller, _platform);
    }
    _suppressFutureErrors(handlerFuture, stepName, _log);
    _pendingFutures[pending.callId] = _PendingFuture(
      future: handlerFuture,
      bridgeCallId: callId,
      stepName: stepName,
    );

    return (_platform as MontyFutureCapable).resumeAsFuture();
  }

  /// Awaits futures for the call IDs listed in [resolve], emitting result
  /// events and resuming the platform with the collected outcomes.
  ///
  /// When no pending futures exist, resumes normally without awaiting.
  Future<MontyProgress> resolveFutures(
    MontyResolveFutures resolve,
    StreamController<BridgeEvent> controller,
  ) async {
    if (_pendingFutures.isEmpty) return _platform.resume(null);
    final results = <int, Object?>{};
    final errors = <int, String>{};
    final entries = <int, _PendingFuture>{};
    for (final id in resolve.pendingCallIds) {
      final pending = _pendingFutures.remove(id);
      if (pending != null) entries[id] = pending;
    }

    for (final entry in entries.entries) {
      final id = entry.key;
      final pending = entry.value;
      try {
        final value = await pending.future;
        results[id] = value;
        controller
          ..add(
            BridgeFunctionCallResult(
              callId: pending.bridgeCallId,
              result: value?.toString() ?? '',
            ),
          )
          ..add(BridgeCallFinished(callId: pending.bridgeCallId));
      } on Object catch (e) {
        errors[id] = e.toString();
        controller
          ..add(
            BridgeFunctionCallResult(
              callId: pending.bridgeCallId,
              result: 'Error: $e',
            ),
          )
          ..add(BridgeCallFinished(callId: pending.bridgeCallId));
      }
    }

    return (_platform as MontyFutureCapable).resolveFutures(
      results,
      errors: errors.isEmpty ? null : errors,
    );
  }

  /// Clears all tracked pending futures.
  ///
  /// Called from `PlatformBridge._run`'s `finally` block to avoid leaking
  /// futures across executions when a run ends unexpectedly.
  void clearPendingFutures() => _pendingFutures.clear();
}
