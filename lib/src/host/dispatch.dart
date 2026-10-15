import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart'
    show DispatchMode, HostFunction;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

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

/// Writes [root] to [out] as its `toString()` reads for a [List], a [Set]
/// or a [Map] (a container already being written is `[...]` or `{...}`, as
/// Dart writes it), and as its own `toString()` otherwise. Iterative, so
/// nesting depth costs no call stack; throws [_TooLong] as soon as [out]
/// would pass [_textLimit], so the work is bounded by the output. An
/// object's own `toString()` (not a list, set or map) is called as it is.
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
          put('$value');
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

/// [value]'s text ([_writeText]), cut at [_textLimit] characters with a
/// note saying so.
String _boundedText(Object? value) {
  final out = StringBuffer();
  try {
    _writeText(value, out);
  } on _TooLong {
    out.write('... (cut at $_textLimit characters)');
  }

  return out.toString();
}

/// [result] as [BridgeFunctionCallResult.result]: its text
/// ([_boundedText]), `''` for null.
String _resultText(Object? result) =>
    result == null ? '' : _boundedText(result);

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
          _writeText(o, out);
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
    HostSubExecutor? subExecute,
  }) : _log = log,
       _runtime = runtime,
       _subExecute = subExecute;

  /// Current OS call handler — mirrored from the owning bridge so handlers
  /// receive it via [HostContext.os]. Updated by the bridge's `registerOs`.
  OsHandler? osHandler;

  final BridgeLogger _log;
  final MontyRuntimeRef? _runtime;

  /// Every handler's [HostContext.subExecute]: the runtime's, or none.
  final HostSubExecutor? _subExecute;

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
    final validatedArgs = mapAndValidate(
      fn.schema,
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
      subExecute: _subExecute,
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
  ///
  /// Each call's [HostContext] carries [os] (the run's OS handler) and
  /// [cancelToken] (the run's token; a fresh one when null).
  Map<String, MontyValue> externals(
    void Function(BridgeEvent) emit, {
    OsHandler? os,
    CancelToken? cancelToken,
  }) {
    Future<MontyValue> call(
      HostFunction fn,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    ) => _call(fn, args, kwargs, emit, os: os, cancelToken: cancelToken);

    return {
      for (final MapEntry(key: name, value: fn) in _functions.entries)
        name: MontyHostFunction(name, switch (fn.dispatch) {
          DispatchMode.sync => (args, kwargs) => call(fn, args, kwargs),
          DispatchMode.future => coroutine(
            (args, kwargs) => call(fn, args, kwargs),
          ),
        }),
    };
  }

  /// One call of [fn] from Python, with its events.
  ///
  /// Emits [BridgeCallStarted] and [BridgeFunctionCallStart], then either
  /// [BridgeFunctionCallArgs] (the validated arguments as JSON) and
  /// [BridgeFunctionCallEnd], the handler's own events, and the result, or,
  /// when validation fails, the result alone. The result is
  /// [BridgeFunctionCallResult] (the value's text, `''` for null, or
  /// `Error: <error>`, each bounded as [_boundedText]) followed by
  /// [BridgeCallFinished].
  ///
  /// The value reaches Python through [MontyValue.fromDart]. A failure,
  /// validation's or the handler's (a value [MontyValue.fromDart] refuses
  /// included), is thrown as `ExternalException('RuntimeError', text)`,
  /// except a handler's own [ExternalException], which is thrown as it is.
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

    final Map<String, Object?> validated;
    try {
      validated = mapAndValidate(fn.schema, args, kwargs);
    } on Object catch (e) {
      final text = fail(e);
      _log.warning(
        'Argument validation failed',
        attributes: {'function': name, 'error': text},
      );
      throw ExternalException('RuntimeError', text);
    }
    emit(BridgeFunctionCallArgs(callId: callId, delta: _argsJson(validated)));
    emit(BridgeFunctionCallEnd(callId: callId));

    final ctx = HostContext(
      emit: emit,
      executionId: callId,
      cancelToken: cancelToken,
      os: os,
      parent: _runtime,
      subExecute: _subExecute,
    );
    final Object? result;
    final MontyValue value;
    try {
      result = await fn.handler!(validated, ctx);
      value = MontyValue.fromDart(result);
    } on Object catch (e, st) {
      final text = fail(e);
      _log.error(
        'Host handler error',
        error: text,
        stackTrace: st,
        attributes: {'function': name, 'type': '${e.runtimeType}'},
      );
      if (e is ExternalException) rethrow;
      throw ExternalException('RuntimeError', text);
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
