import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_logger.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

const _roleKwarg = '__role__';

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
// Top-level helpers shared by PluginHost dispatch methods.
// ---------------------------------------------------------------------------

/// Invokes [fn] through [middleware], or calls the handler directly when
/// no middleware is registered.
///
/// First registered = outermost in the onion chain.
Future<Object?> _invokeWithMiddleware(
  List<BridgeMiddleware> middleware,
  HostFunction fn,
  String name,
  Map<String, Object?> args,
  CallRole role,
) {
  if (middleware.isEmpty) return fn.handler(args);

  var handler = (String _, Map<String, Object?> a) => fn.handler(a);
  for (final mw in middleware.reversed) {
    final next = handler;
    handler = (n, a) => mw.handle(n, a, role, next);
  }

  return handler(name, args);
}

/// Validates [pending] arguments against [fn]'s schema and emits the
/// `BridgeToolCallArgs`/`BridgeToolCallEnd` events on success.
///
/// Returns the validated arg map, or `null` when validation fails (the
/// `BridgeToolCallResult`/`BridgeStepFinished` error events are already
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
      ..add(BridgeToolCallResult(callId: callId, result: 'Error: $e'))
      ..add(BridgeStepFinished(stepId: stepName));
    setResumeError(e.toString());

    return null;
  }
  controller
    ..add(BridgeToolCallArgs(callId: callId, delta: jsonEncode(args)))
    ..add(BridgeToolCallEnd(callId: callId));

  return args;
}

/// Emits [BridgeToolCallResult] + [BridgeStepFinished] for a handler error
/// and returns `platform.resumeWithError`.
Future<MontyProgress> _emitToolCallError(
  String callId,
  String stepName,
  String error,
  StreamController<BridgeEvent> controller,
  MontyPlatform platform,
) {
  controller
    ..add(BridgeToolCallResult(callId: callId, result: 'Error: $error'))
    ..add(BridgeStepFinished(stepId: stepName));

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
// PluginHost — function registry + tool dispatch.
// ---------------------------------------------------------------------------

/// Manages host function registration, middleware, and tool call dispatch
/// for a `DefaultMontyBridge`.
///
/// This is an internal implementation-detail class — it is not part of the
/// public `MontyBridge` API. Callers access it through the bridge's delegation
/// methods.
@internal
class PluginHost {
  /// Creates a [PluginHost].
  ///
  /// [platform] is required for dispatching resume/resumeWithError calls.
  /// [log] is used for warning/error messages emitted during dispatch.
  PluginHost({
    required MontyPlatform platform,
    required BridgeLogger log,
  }) : _platform = platform,
       _log = log;

  final MontyPlatform _platform;
  final BridgeLogger _log;

  final Map<String, HostFunction> _functions = {};
  final Map<String, Set<String>> _categoryIndex = {};
  final List<BridgeMiddleware> _middleware = [];

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

  /// Registers a middleware interceptor.
  void use(BridgeMiddleware middleware) => _middleware.add(middleware);

  /// Registers [function] under an optional [category].
  void register(HostFunction function, {String? category}) {
    final name = function.schema.name;
    _functions[name] = function;
    (_categoryIndex[category ?? 'uncategorized'] ??= {}).add(name);
  }

  /// Unregisters the function with [name].
  void unregister(String name) => _functions.remove(name);

  /// Invokes a registered host function by [name] directly from Dart,
  /// routing through the middleware chain.
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    CallRole role = const ToolCall(),
  }) {
    final fn = _functions[name];
    if (fn == null) throw ArgumentError('Unknown host function: $name');
    final pending = MontyPending(
      functionName: name,
      arguments: const [],
      kwargs: args.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
    );
    final validatedArgs = fn.schema.mapAndValidate(pending);

    return _invokeWithMiddleware(_middleware, fn, name, validatedArgs, role);
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

    // Registered host function — extract role, strip reserved kwargs, dispatch.
    final fn = _functions[name];
    if (fn != null) {
      final (cleanedPending, role) = _extractRole(pending, fn.role);
      _log.trace('Host function call', attributes: {'name': name});

      return futuresCapable
          ? dispatchToolCallAsFuture(fn, cleanedPending, controller, role: role)
          : dispatchToolCall(fn, cleanedPending, controller, role: role);
    }

    // Unknown function — raise error in Python.
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
    StreamController<BridgeEvent> controller, {
    required CallRole role,
  }) async {
    final callId = nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeStepStarted(stepId: stepName))
      ..add(BridgeToolCallStart(callId: callId, name: stepName));

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

    final Object? result;
    try {
      result = await _invokeWithMiddleware(
        _middleware,
        fn,
        stepName,
        args,
        role,
      );
    } on Object catch (e, st) {
      _log.error(
        'Host handler error',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );

      return _emitToolCallError(callId, stepName, '$e', controller, _platform);
    }

    controller
      ..add(
        BridgeToolCallResult(callId: callId, result: result?.toString() ?? ''),
      )
      ..add(BridgeStepFinished(stepId: stepName));

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
    StreamController<BridgeEvent> controller, {
    required CallRole role,
  }) {
    final callId = nextId;
    final stepName = pending.functionName;

    controller
      ..add(BridgeStepStarted(stepId: stepName))
      ..add(BridgeToolCallStart(callId: callId, name: stepName));

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

    final Future<Object?> handlerFuture;
    try {
      handlerFuture = _invokeWithMiddleware(
        _middleware,
        fn,
        stepName,
        args,
        role,
      );
    } on Object catch (e, st) {
      _log.error(
        'Host handler threw synchronously',
        error: e,
        stackTrace: st,
        attributes: {'function': stepName},
      );

      return _emitToolCallError(callId, stepName, '$e', controller, _platform);
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

  /// Clears all tracked pending futures.
  ///
  /// Called from `DefaultMontyBridge._run`'s `finally` block to avoid leaking
  /// futures across executions when a run ends unexpectedly.
  void clearPendingFutures() => _pendingFutures.clear();
}

// ---------------------------------------------------------------------------
// _extractRole — pure function, lives here since it operates on MontyPending
// which is a dispatch concern and references _roleKwarg.
// ---------------------------------------------------------------------------

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

  if (hostRole != null) return (cleanedPending, hostRole);

  final roleValue = kwargs?[_roleKwarg]?.dartValue;
  final role = switch (roleValue) {
    'infra' => const InfraCall(),
    _ => const ToolCall(),
  };

  return (cleanedPending, role);
}
