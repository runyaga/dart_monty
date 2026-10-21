import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart'
    show DispatchMode, HostFunction, HostFunctionParityInternal;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Bounds rendered log values without affecting execution.
const int _textLimit = 1 << 20;

/// Thrown once a bounded writer passes [_textLimit].
final class _TooLong implements Exception {
  const _TooLong();

  @override
  String toString() => 'over $_textLimit characters';
}

/// Stops retaining rendered text after the logging limit.
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

/// A value still to write ([_writeText]).
final class _Value {
  const _Value(this.value);

  final Object? value;
}

/// A map entry still to write ([_writeText]).
final class _Entry {
  const _Entry(this.key, this.value);

  final Object? key;
  final Object? value;
}

/// A container being written ([_writeText]): its remaining items.
final class _Open {
  _Open(this.container, this.items, this.close);

  final Object container;
  final Iterator<Object?> items;
  final String close;
  bool first = true;
}

/// Renders bounded collection text while detecting identity cycles.
void _writeText(Object? root, StringBuffer out) {
  void put(String text) {
    if (out.length + text.length > _textLimit) throw const _TooLong();
    out.write(text);
  }

  final open = HashSet<Object>.identity();
  // Literal strings, values, entries and open containers, last on top.
  final todo = <Object>[_Value(root)];
  while (todo.isNotEmpty) {
    switch (todo.removeLast()) {
      case final String literal:
        put(literal);
      case _Entry(:final key, :final value):
        todo
          ..add(_Value(value))
          ..add(': ')
          ..add(_Value(key));
      case _Value(:final value):
        final (opening, items, closing) = switch (value) {
          MontyList(:final items) ||
          MontyTuple(:final items) => ('[', items.iterator, ']'),
          MontyDict(:final pairs) => (
            '{',
            pairs.map((pair) => _Entry(pair.$1, pair.$2)).iterator,
            '}',
          ),
          final List<Object?> l => ('[', l.iterator, ']'),
          final Set<Object?> s => ('{', s.iterator, '}'),
          final Map<Object?, Object?> m => (
            '{',
            m.entries.map((e) => _Entry(e.key, e.value)).iterator,
            '}',
          ),
          _ => (null, null, null),
        };
        if (opening == null || items == null || closing == null) {
          put('${value is MontyValue ? value.dartValue : value}');
        } else if (!open.add(value!)) {
          put('$opening...$closing');
        } else {
          put(opening);
          todo.add(_Open(value, items, closing));
        }
      case final _Open frame:
        if (!frame.items.moveNext()) {
          open.remove(frame.container);
          put(frame.close);
          continue;
        }
        final item = frame.items.current;
        todo
          ..add(frame)
          ..add(item is _Entry ? item : _Value(item));
        if (!frame.first) todo.add(', ');
        frame.first = false;
    }
  }
}

/// Renders one value within the logging limit.
String _boundedText(Object value) {
  final out = StringBuffer();
  try {
    _writeText(value, out);
  } on _TooLong {
    out.write('... (cut at $_textLimit characters)');
  }

  return out.toString();
}

/// Renders a host result for its bridge event.
String _resultText(MontyValue result) =>
    result is MontyNone ? '' : _boundedText(result);

/// Formats an upstream-compatible result-conversion failure.
String _parityConversionMessage(Object? value) {
  final typeName = value.runtimeType == Object
      ? 'builtins.object'
      : '${value.runtimeType}';

  return 'Cannot convert $typeName to Monty value — '
      'wrap class instances in pydantic_monty.ClassInstance(...)';
}

MontyValue _toMontyValue(Object? raw) => switch (raw) {
  null => const MontyNone(),
  final MontyValue value => value,
  _ => MontyValue.fromDart(raw),
};

Future<MontyValue> _invokeParityDirect(
  HostFunction fn,
  Map<String, MontyValue> args,
  HostContext ctx,
  BridgeLogger log,
) async {
  final Map<String, MontyValue> validatedArgs;
  try {
    validatedArgs = mapAndValidateParity(fn.schema, const [], args);
  } on ParityBindingException catch (e) {
    throw ExternalException('TypeError', e.message);
  }

  final raw = await fn.parityHandler!(validatedArgs, ctx);
  try {
    return _toMontyValue(raw);
  } on Object catch (e, st) {
    final message = _parityConversionMessage(raw);
    log.error(
      'Host result serialization error',
      error: 'TypeError: $message',
      stackTrace: st,
      attributes: {
        'function': fn.schema.name,
        'type': '${raw.runtimeType}',
        'errorType': '${e.runtimeType}',
      },
    );
    throw ExternalException('TypeError', message);
  }
}

Future<Object?> _invokeParityCall(
  HostFunction fn,
  Map<String, MontyValue> validated,
  HostContext ctx,
  String Function(Object) fail,
  BridgeLogger log,
) async {
  final Object? raw;
  try {
    raw = await fn.parityHandler!(validated, ctx);
  } on Object catch (e, st) {
    final text = fail(e);
    log.error(
      'Host handler error',
      error: text,
      stackTrace: st,
      attributes: {'function': fn.schema.name, 'type': '${e.runtimeType}'},
    );
    if (e is ExternalException) rethrow;
    throw ExternalException('RuntimeError', text);
  }

  return raw;
}

/// Renders bounded host arguments for a bridge event without failing the call.
String _argsJson(Map<String, MontyValue> args) {
  final sink = _BoundedSink();
  // A value's own text past the limit: the encoder would wrap a throw from
  // here in an Error, so it is recorded instead.
  var valueTooLong = false;
  try {
    JsonEncoder((o) {
        final out = StringBuffer();
        try {
          _writeText(o, out);
        } on _TooLong {
          valueTooLong = true;
        }

        return out.toString();
      }).startChunkedConversion(sink)
      ..add(args.map((key, value) => MapEntry(key, value.dartValue)))
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

/// Runs sub-execution with the parent call's cancellation token.
typedef RuntimeSubExecutor =
    Future<MontyValue> Function(
      String code, {
      Map<String, MontyValue>? inputs,
      CancelToken? cancelToken,
    });

// ---------------------------------------------------------------------------
// HostDispatch manages the function registry and tool dispatch.
// ---------------------------------------------------------------------------

/// Manages bridge host registration and dispatch.
@internal
class HostDispatch {
  /// Creates host dispatch with runtime and logging context.
  HostDispatch({
    required BridgeLogger log,
    required MontyRuntimeRef? runtime,
    required RuntimeSubExecutor? subExecute,
  }) : _log = log,
       _runtime = runtime,
       _subExecute = subExecute;

  /// Mirrors the owning bridge's OS handler into host contexts.
  OsHandler? osHandler;

  final BridgeLogger _log;
  final MontyRuntimeRef? _runtime;

  /// The runtime's sub-executor, or none.
  final RuntimeSubExecutor? _subExecute;

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

  /// Registers a function when it supports the current backend.
  void register(HostFunction function, {String? category}) {
    if (!function.hasActiveHandler) return;
    validateDefaults(function.schema);
    final name = function.schema.name;
    _functions[name] = function;
    (_categoryIndex[category ?? 'uncategorized'] ??= {}).add(name);
  }

  /// Unregisters the function with [name].
  void unregister(String name) => _functions.remove(name);

  /// Invokes a registered function without Python execution or stream wrappers.
  Future<MontyValue> invokeHostFunction(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  }) {
    final fn = _functions[name];
    if (fn == null) throw ArgumentError('Unknown host function: $name');
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
      subExecute: _subExecuteFor(null),
    );
    if (fn.isParity) {
      return _invokeParityDirect(fn, args, ctx, _log);
    }
    final validatedArgs = mapAndValidate(
      fn.schema,
      const [],
      args,
    );

    return fn.handler!(validatedArgs, ctx);
  }

  // ---------------------------------------------------------------------------
  // Calls from Python.
  // ---------------------------------------------------------------------------

  /// Builds the feed lookup that reports host calls through the event sink.
  Map<String, MontyValue> externals(
    void Function(BridgeEvent) emit, {
    required OsHandler? os,
    required CancelToken? cancelToken,
  }) {
    Future<MontyValue> call(
      HostFunction fn,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    ) => _call(fn, args, kwargs, emit, os: os, cancelToken: cancelToken);

    Future<Object?> callParity(
      HostFunction fn,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    ) => _callParity(fn, args, kwargs, emit, os: os, cancelToken: cancelToken);

    return {
      for (final MapEntry(key: name, value: fn) in _functions.entries)
        name: fn.isParity
            ? MontyHostFunction.parity(name, switch (fn.dispatch) {
                DispatchMode.sync => (args, kwargs) => callParity(
                  fn,
                  args,
                  kwargs,
                ),
                DispatchMode.future => parityCoroutine(
                  (args, kwargs) => callParity(fn, args, kwargs),
                ),
              })
            : MontyHostFunction(name, switch (fn.dispatch) {
                DispatchMode.sync => (args, kwargs) => call(fn, args, kwargs),
                DispatchMode.future => coroutine(
                  (args, kwargs) => call(fn, args, kwargs),
                ),
              }),
    };
  }

  /// Binds runtime sub-execution to the current cancellation token.
  HostSubExecutor? _subExecuteFor(CancelToken? cancelToken) {
    final subExecute = _subExecute;
    if (subExecute == null) return null;

    return (code, {inputs}) =>
        subExecute(code, inputs: inputs, cancelToken: cancelToken);
  }

  /// Converts legacy argument-binding failures to Python `RuntimeError` before
  /// invoking the handler.
  Map<String, MontyValue> _validateCall(
    HostFunction fn,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
    String Function(Object) fail,
  ) {
    try {
      return fn.isParity
          ? mapAndValidateParity(fn.schema, args, kwargs)
          : mapAndValidate(fn.schema, args, kwargs);
    } on ParityBindingException catch (e) {
      final text = fail(e.message);
      _log.warning(
        'Argument validation failed',
        attributes: {'function': fn.schema.name, 'error': text},
      );
      throw ExternalException('TypeError', text);
    } on Object catch (e) {
      final text = fail(e);
      _log.warning(
        'Argument validation failed',
        attributes: {'function': fn.schema.name, 'error': text},
      );
      throw ExternalException('RuntimeError', text);
    }
  }

  /// Runs one Python-originated host call and emits its ordered events.
  Future<MontyValue> _call(
    HostFunction fn,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
    void Function(BridgeEvent) emit, {
    required OsHandler? os,
    required CancelToken? cancelToken,
  }) async {
    final name = fn.schema.name;
    final callId = nextId;
    _log.trace('Host function call', attributes: {'name': name});
    emit(BridgeCallStarted(callId: callId));
    emit(BridgeFunctionCallStart(callId: callId, name: name));
    // A failure's text is bounded once, and the log, the event and the
    // Python exception all use it.
    String fail(Object error) {
      final text = _boundedText(error);
      emit(BridgeFunctionCallResult(callId: callId, result: 'Error: $text'));
      emit(BridgeCallFinished(callId: callId));

      return text;
    }

    final validated = _validateCall(fn, args, kwargs, fail);
    emit(BridgeFunctionCallArgs(callId: callId, delta: _argsJson(validated)));
    emit(BridgeFunctionCallEnd(callId: callId));

    final ctx = _contextFor(callId, emit, os, cancelToken);
    final value = await _invokeCall(fn, validated, ctx, fail);
    emit(BridgeFunctionCallResult(callId: callId, result: _resultText(value)));
    emit(BridgeCallFinished(callId: callId));

    return value;
  }

  Future<Object?> _callParity(
    HostFunction fn,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
    void Function(BridgeEvent) emit, {
    required OsHandler? os,
    required CancelToken? cancelToken,
  }) async {
    final name = fn.schema.name;
    final callId = nextId;
    _log.trace('Host function call', attributes: {'name': name});
    emit(BridgeCallStarted(callId: callId));
    emit(BridgeFunctionCallStart(callId: callId, name: name));
    String fail(Object error) {
      final text = _boundedText(error);
      emit(BridgeFunctionCallResult(callId: callId, result: 'Error: $text'));
      emit(BridgeCallFinished(callId: callId));

      return text;
    }

    final validated = _validateCall(fn, args, kwargs, fail);
    emit(BridgeFunctionCallArgs(callId: callId, delta: _argsJson(validated)));
    emit(BridgeFunctionCallEnd(callId: callId));

    final ctx = _contextFor(callId, emit, os, cancelToken);
    final raw = await _invokeParityCall(fn, validated, ctx, fail, _log);

    return _emitParityResult(callId, name, raw, emit);
  }

  Object? _emitParityResult(
    String callId,
    String name,
    Object? raw,
    void Function(BridgeEvent) emit,
  ) {
    final MontyValue serialized;
    try {
      serialized = _toMontyValue(raw);
    } on Object catch (e, st) {
      final text = 'TypeError: ${_parityConversionMessage(raw)}';
      _log.error(
        'Host result serialization error',
        error: text,
        stackTrace: st,
        attributes: {
          'function': name,
          'type': '${raw.runtimeType}',
          'errorType': '${e.runtimeType}',
        },
      );
      emit(BridgeFunctionCallResult(callId: callId, result: text));
      emit(BridgeCallFinished(callId: callId));

      return raw;
    }
    emit(
      BridgeFunctionCallResult(callId: callId, result: _resultText(serialized)),
    );
    emit(BridgeCallFinished(callId: callId));

    return serialized;
  }

  HostContext _contextFor(
    String callId,
    void Function(BridgeEvent) emit,
    OsHandler? os,
    CancelToken? cancelToken,
  ) => HostContext(
    emit: emit,
    executionId: callId,
    cancelToken: cancelToken,
    os: os,
    parent: _runtime,
    subExecute: _subExecuteFor(cancelToken),
  );

  Future<MontyValue> _invokeCall(
    HostFunction fn,
    Map<String, MontyValue> validated,
    HostContext ctx,
    String Function(Object) fail,
  ) async {
    final MontyValue value;
    try {
      value = await fn.handler!(validated, ctx);
    } on Object catch (e, st) {
      final text = fail(e);
      _log.error(
        'Host handler error',
        error: text,
        stackTrace: st,
        attributes: {'function': fn.schema.name, 'type': '${e.runtimeType}'},
      );
      if (e is ExternalException) rethrow;
      throw ExternalException('RuntimeError', text);
    }

    return value;
  }
}
