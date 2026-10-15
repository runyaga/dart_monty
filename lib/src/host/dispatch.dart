import 'dart:async';
import 'dart:convert';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart'
    show DispatchMode, HostFunction;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Default [HostSubExecutor] wired into every [HostContext]: a sub-execution
/// on a second session, built in D1-6.
Future<MontyValue> _defaultSubExecute(
  String code, {
  Map<String, Object?>? inputs,
}) => throw UnimplementedError('D1-6');

/// The most characters [_argsJson] or [_resultText] writes before it gives
/// up: a list shared at each level of a value expands at every use, so a
/// small value can have an enormous text.
const int _textLimit = 1 << 20;

/// Thrown once a bounded writer passes [_textLimit].
final class _TooLong implements Exception {
  const _TooLong();

  @override
  String toString() => 'over $_textLimit characters';
}

/// A string sink that throws [_TooLong] once more than [_textLimit]
/// characters were added, so an encoder writing into it stops there.
final class _BoundedSink implements Sink<String> {
  final StringBuffer _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  void add(String data) {
    if (_buffer.length + data.length > _textLimit) throw const _TooLong();
    _buffer.write(data);
  }

  @override
  void close() {}
}

/// Writes [value] to [out] as its `toString()` reads for a [List], a [Set]
/// or a [Map] (a container already being written is `[...]` or `{...}`, as
/// Dart writes it), and as its `toString()` otherwise. Throws [_TooLong] as
/// soon as [out] passes [_textLimit], so the work is bounded too.
void _writeText(Object? value, StringBuffer out, List<Object> open) {
  void put(String text) {
    if (out.length + text.length > _textLimit) throw const _TooLong();
    out.write(text);
  }

  if (value == null || (value is! List && value is! Set && value is! Map)) {
    put('$value');

    return;
  }
  if (open.any((o) => identical(o, value))) {
    put(value is List ? '[...]' : '{...}');

    return;
  }
  open.add(value);
  var first = true;
  void separate() {
    if (!first) put(', ');
    first = false;
  }

  switch (value) {
    case final List<Object?> list:
      put('[');
      for (final e in list) {
        separate();
        _writeText(e, out, open);
      }
      put(']');
    case final Set<Object?> set:
      put('{');
      for (final e in set) {
        separate();
        _writeText(e, out, open);
      }
      put('}');
    case final Map<Object?, Object?> map:
      put('{');
      for (final MapEntry(:key, value: v) in map.entries) {
        separate();
        _writeText(key, out, open);
        put(': ');
        _writeText(v, out, open);
      }
      put('}');
  }
  open.removeLast();
}

/// [result] as [BridgeFunctionCallResult.result]: its `toString()`, `''`
/// for null. Past [_textLimit] characters it is cut there and says so.
String _resultText(Object? result) {
  if (result == null) return '';
  final out = StringBuffer();
  try {
    _writeText(result, out, []);
  } on _TooLong {
    out.write('... (cut at $_textLimit characters)');
  }

  return out.toString();
}

/// [args] as JSON for [BridgeFunctionCallArgs.delta]: a value JSON has no
/// form for is written as its text ([_writeText]).
///
/// Never throws. Arguments whose JSON would pass [_textLimit] characters,
/// or that hold a cycle, are written as a JSON string saying so, and the
/// call goes on.
String _argsJson(Map<String, Object?> args) {
  final sink = _BoundedSink();
  // A value's own text past the limit: the encoder would wrap a throw from
  // here in an Error, so it is recorded instead.
  var valueTooLong = false;
  try {
    JsonEncoder((o) {
        final out = StringBuffer();
        try {
          _writeText(o, out, []);
        } on _TooLong {
          valueTooLong = true;
        }

        return out.toString();
      }).startChunkedConversion(sink)
      ..add(args)
      ..close();
  } on _TooLong catch (e) {
    return jsonEncode('arguments not shown: $e of JSON');
  } on Object catch (e) {
    // The encoder wraps a throw made while writing a converted value.
    final tooLong =
        valueTooLong ||
        (e is JsonUnsupportedObjectError && e.cause is _TooLong);

    return jsonEncode(
      'arguments not shown: '
      '${tooLong ? '${const _TooLong()} of JSON' : e.runtimeType}',
    );
  }

  return valueTooLong
      ? jsonEncode('arguments not shown: ${const _TooLong()} of JSON')
      : sink.text;
}

// ---------------------------------------------------------------------------
// HostDispatch — function registry + tool dispatch.
// ---------------------------------------------------------------------------

/// Manages host function registration and tool call dispatch for a
/// `MontyBridge`.
///
/// This is an internal implementation-detail class — it is not part of the
/// public `MontyBridge` API. Callers access it through the bridge's delegation
/// methods.
@internal
class HostDispatch {
  /// Creates a [HostDispatch].
  ///
  /// [log] is used for warning/error messages emitted during dispatch.
  HostDispatch({
    required BridgeLogger log,
    MontyRuntimeRef? runtime,
  }) : _log = log,
       _runtime = runtime;

  /// Current OS call handler — mirrored from the owning bridge so handlers
  /// receive it via [HostContext.os]. Updated by the bridge's `registerOs`.
  OsHandler? osHandler;

  final BridgeLogger _log;
  final MontyRuntimeRef? _runtime;

  final Map<String, HostFunction> _functions = {};
  final Map<String, Set<String>> _categoryIndex = {};

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
    final validatedArgs = fn.schema.mapAndValidate(
      const [],
      args.map((k, v) => MapEntry(k, MontyValue.fromDart(v))),
    );
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

    return fn.handler!(validatedArgs, ctx);
  }

  // ---------------------------------------------------------------------------
  // Calls from Python.
  // ---------------------------------------------------------------------------

  /// The registered functions as a feed's `externalLookup`, each wrapped so
  /// its calls emit their events through [emit].
  ///
  /// A [DispatchMode.future] function is marked with core's [coroutine]: a
  /// call is a coroutine in the sandbox, settled when its handler's future
  /// completes. A [DispatchMode.sync] function is unmarked: core awaits the
  /// handler and Python sees the value at the call site. A name not in the
  /// map is Python's `NameError`, raised by the worker without reaching dm.
  Map<String, MontyValue> externals(void Function(BridgeEvent) emit) => {
    for (final MapEntry(key: name, value: fn) in _functions.entries)
      name: MontyHostFunction(name, switch (fn.dispatch) {
        DispatchMode.sync => (args, kwargs) => _call(fn, args, kwargs, emit),
        DispatchMode.future => coroutine(
          (args, kwargs) => _call(fn, args, kwargs, emit),
        ),
      }),
  };

  /// One call of [fn] from Python, with its events.
  ///
  /// Emits [BridgeCallStarted] and [BridgeFunctionCallStart], then either
  /// [BridgeFunctionCallArgs] (the validated arguments as JSON) and
  /// [BridgeFunctionCallEnd], the handler's own events, and the result, or,
  /// when validation fails, the result alone. The result is
  /// [BridgeFunctionCallResult] (the value's `toString()`, `''` for null, or
  /// `Error: <error>`) followed by [BridgeCallFinished].
  ///
  /// The value reaches Python through [MontyValue.fromDart]. A failure,
  /// validation's or the handler's (a value [MontyValue.fromDart] refuses
  /// included), is thrown as `ExternalException('RuntimeError', text)`,
  /// except a handler's own [ExternalException], which is thrown as it is.
  Future<MontyValue> _call(
    HostFunction fn,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
    void Function(BridgeEvent) emit,
  ) async {
    final name = fn.schema.name;
    final callId = nextId;
    _log.trace('Host function call', attributes: {'name': name});
    emit(BridgeCallStarted(callId: callId));
    emit(BridgeFunctionCallStart(callId: callId, name: name));
    void fail(Object error) {
      emit(BridgeFunctionCallResult(callId: callId, result: 'Error: $error'));
      emit(BridgeCallFinished(callId: callId));
    }

    final Map<String, Object?> validated;
    try {
      validated = fn.schema.mapAndValidate(args, kwargs);
    } on Object catch (e) {
      _log.warning(
        'Argument validation failed',
        attributes: {'function': name, 'error': '$e'},
      );
      fail(e);
      throw ExternalException('RuntimeError', '$e');
    }
    emit(BridgeFunctionCallArgs(callId: callId, delta: _argsJson(validated)));
    emit(BridgeFunctionCallEnd(callId: callId));

    final ctx = HostContext(
      emit: emit,
      executionId: callId,
      os: osHandler,
      parent: _runtime,
      subExecute: _defaultSubExecute,
    );
    final Object? result;
    final MontyValue value;
    try {
      result = await fn.handler!(validated, ctx);
      value = MontyValue.fromDart(result);
    } on Object catch (e, st) {
      _log.error(
        'Host handler error',
        error: e,
        stackTrace: st,
        attributes: {'function': name},
      );
      fail(e);
      if (e is ExternalException) rethrow;
      throw ExternalException('RuntimeError', '$e');
    }
    emit(
      BridgeFunctionCallResult(
        callId: callId,
        result: _resultText(result),
      ),
    );
    emit(BridgeCallFinished(callId: callId));

    return value;
  }
}
