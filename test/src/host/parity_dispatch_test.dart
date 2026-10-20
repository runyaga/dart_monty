import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/schema.dart'
    show ParityBindingException, mapAndValidateParity;
import 'package:dart_monty_core/dart_monty_core.dart' show MontyHostFunction;
import 'package:test/test.dart';

/// Tests of `HostFunction.parity` dispatch: the direct-Dart path
/// (`HostDispatch.invokeHostFunction`) and the Python path
/// (`HostDispatch.externals`, as a session's `externalLookup` entry is
/// invoked), with the events each call emits and the errors each failure
/// raises. Drives `HostDispatch` directly, as `function_test.dart` does:
/// no session, no worker.

/// A host class instance a parity handler returns unconverted.
final class _Wand {
  const _Wand();
}

/// One recorded log message: its level, text, error and attributes.
typedef _Logged = ({
  String level,
  String message,
  Object? error,
  Map<String, Object?>? attributes,
});

/// A logger that records every message it receives, for asserting the
/// log calls the dispatch paths make.
final class _RecordingLogger implements BridgeLogger {
  final List<_Logged> messages = [];

  @override
  void trace(String message, {Map<String, Object?>? attributes}) =>
      messages.add((
        level: 'trace',
        message: message,
        error: null,
        attributes: attributes,
      ));

  @override
  void debug(String message, {Map<String, Object?>? attributes}) =>
      messages.add((
        level: 'debug',
        message: message,
        error: null,
        attributes: attributes,
      ));

  @override
  void info(String message, {Map<String, Object?>? attributes}) =>
      messages.add((
        level: 'info',
        message: message,
        error: null,
        attributes: attributes,
      ));

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages.add((
    level: 'warning',
    message: message,
    error: error,
    attributes: attributes,
  ));

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? attributes,
  }) => messages.add((
    level: 'error',
    message: message,
    error: error,
    attributes: attributes,
  ));

  @override
  BridgeLogger child(String name) => this;

  @override
  // ignore: no-empty-block, the fake holds no resources.
  void close() {}
}

/// The schema of a parity function taking one required integer `x`.
const _xSchema = HostFunctionSchema(
  name: 'fn',
  params: [HostParam(name: 'x', type: HostParamType.integer)],
);

/// [event] as one line: its kind without the `Bridge` prefix and its ids
/// and payload, for comparing event sequences.
String _describe(BridgeEvent event) => switch (event) {
  BridgeCallStarted(:final callId) => 'CallStarted $callId',
  BridgeFunctionCallStart(:final callId, :final name) =>
    'FunctionCallStart $callId $name',
  BridgeFunctionCallArgs(:final callId, :final delta) =>
    'FunctionCallArgs $callId $delta',
  BridgeFunctionCallEnd(:final callId) => 'FunctionCallEnd $callId',
  BridgeFunctionCallResult(:final callId, :final result) =>
    'FunctionCallResult $callId $result',
  BridgeCallFinished(:final callId) => 'CallFinished $callId',
  _ => '${event.runtimeType}',
};

/// A `TypeError` [ExternalException] carrying [message], as the parity
/// paths raise for binding and conversion failures.
Matcher _throwsTypeError(Object message) => throwsA(
  isA<ExternalException>()
      .having((e) => e.excType, 'excType', 'TypeError')
      .having((e) => e.message, 'message', message),
);

void main() {
  /// A fresh dispatch with its event sink and its recording logger.
  ({HostDispatch dispatch, List<BridgeEvent> events, _RecordingLogger log})
  fresh() {
    final events = <BridgeEvent>[];
    final log = _RecordingLogger();

    return (
      dispatch: HostDispatch(log: log, runtime: null, subExecute: null),
      events: events,
      log: log,
    );
  }

  group('invokeHostFunction (the direct-Dart parity path)', () {
    test('converts a Dart value, a MontyValue and null', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => (args['x']! as MontyInt).value * 2,
          ),
        )
        ..dispatch.register(
          HostFunction.parity(
            schema: const HostFunctionSchema(name: 'raw'),
            handler: (args, _) => const MontyString('kept'),
          ),
        )
        ..dispatch.register(
          HostFunction.parity(
            schema: const HostFunctionSchema(name: 'nothing'),
            handler: (args, _) => null,
          ),
        );

      expect(
        await d.dispatch.invokeHostFunction('fn', const {'x': MontyInt(21)}),
        const MontyInt(42),
      );
      expect(
        await d.dispatch.invokeHostFunction('raw', const {}),
        const MontyString('kept'),
      );
      expect(
        await d.dispatch.invokeHostFunction('nothing', const {}),
        const MontyNone(),
      );
      expect(d.log.messages, isEmpty);
    });

    test('a binding failure raises a Python TypeError', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(schema: _xSchema, handler: (args, _) => null),
        );

      expect(
        d.dispatch.invokeHostFunction('fn', const {}),
        _throwsTypeError("fn() missing 1 required positional argument: 'x'"),
      );
      expect(
        d.dispatch.invokeHostFunction(
          'fn',
          const {'zzz': MontyInt(1)},
        ),
        _throwsTypeError(
          "fn() got an unexpected keyword argument 'zzz'",
        ),
      );
    });

    test(
      'an unconvertible class instance raises the parity TypeError',
      () async {
        const wand = _Wand();
        final d = fresh()
          ..dispatch.register(
            HostFunction.parity(schema: _xSchema, handler: (args, _) => wand),
          );

        final hint =
            'Cannot convert ${wand.runtimeType} to Monty value — '
            'wrap class instances in pydantic_monty.ClassInstance(...)';
        await expectLater(
          d.dispatch.invokeHostFunction('fn', const {'x': MontyInt(1)}),
          _throwsTypeError(hint),
        );
        expect(d.log.messages, hasLength(1));
        final [logged] = d.log.messages;
        expect(logged.level, 'error');
        expect(logged.message, 'Host result serialization error');
        expect(logged.error, 'TypeError: $hint');
        expect(logged.attributes, {
          'function': 'fn',
          'type': '${wand.runtimeType}',
          'errorType': 'ArgumentError',
        });
      },
    );

    test('a plain Object names builtins.object in the TypeError', () {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(schema: _xSchema, handler: (args, _) => Object()),
        );

      expect(
        d.dispatch.invokeHostFunction('fn', const {'x': MontyInt(1)}),
        _throwsTypeError(
          'Cannot convert builtins.object to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)',
        ),
      );
    });

    test('a handler throw reaches the caller unchanged', () {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => throw StateError('wand missing'),
          ),
        );

      expect(
        d.dispatch.invokeHostFunction('fn', const {'x': MontyInt(1)}),
        throwsStateError,
      );
    });

    // `parityHandler` reads the wasm slot only in a browser compile, so
    // this path runs in the Chrome suite, not the VM one.
    test('the wasm slot serves a direct parity call in a browser', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            wasmHandler: (args, _) => (args['x']! as MontyInt).value + 1,
          ),
        );

      expect(
        await d.dispatch.invokeHostFunction('fn', const {'x': MontyInt(41)}),
        const MontyInt(42),
      );
    }, testOn: 'browser');
  });

  group('ParityBindingException', () {
    test('reads as its Python TypeError message', () {
      late ParityBindingException binding;
      try {
        mapAndValidateParity(_xSchema, const [], const {});
      } on ParityBindingException catch (e) {
        binding = e;
      }

      expect(
        binding.toString(),
        "fn() missing 1 required positional argument: 'x'",
      );
    });
  });

  group('externals (the Python parity path)', () {
    test('a sync call emits the call events and converts the result', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => (args['x']! as MontyInt).value * 2,
          ),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      final result = await entry.fn(
        const [MontyInt(3)],
        const {},
      );

      expect(result, const MontyInt(6));
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallArgs 0 {"x":3}',
        'FunctionCallEnd 0',
        'FunctionCallResult 0 6',
        'CallFinished 0',
      ]);
    });

    test('a future-dispatch call reports the same events', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) async => (args['x']! as MontyInt).value * 2,
            dispatch: DispatchMode.future,
          ),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      final result = await entry.fn(const [], const {'x': MontyInt(4)});

      expect(result, const MontyInt(8));
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallArgs 0 {"x":4}',
        'FunctionCallEnd 0',
        'FunctionCallResult 0 8',
        'CallFinished 0',
      ]);
    });

    test('a null result is None with an empty result text', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(schema: _xSchema, handler: (args, _) => null),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      final result = await entry.fn(const [MontyInt(5)], const {});

      expect(result, const MontyNone());
      final [call] = d.events.whereType<BridgeFunctionCallResult>().toList();
      expect(call.result, '');
    });

    test('a MontyValue result passes through unchanged', () async {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => const MontyString('kept'),
          ),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      final result = await entry.fn(const [MontyInt(5)], const {});

      expect(result, const MontyString('kept'));
      final [call] = d.events.whereType<BridgeFunctionCallResult>().toList();
      expect(call.result, 'kept');
    });

    test('a binding failure raises TypeError and fails the call', () {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(schema: _xSchema, handler: (args, _) => null),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      expect(
        entry.fn(const [MontyInt(1), MontyInt(2)], const {}),
        _throwsTypeError('fn() takes 1 positional argument but 2 were given'),
      );
      const over = 'fn() takes 1 positional argument but 2 were given';
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallResult 0 Error: $over',
        'CallFinished 0',
      ]);
      final [warning] = d.log.messages
          .where((m) => m.level == 'warning')
          .toList();
      expect(warning.message, 'Argument validation failed');
      expect(warning.attributes, {'function': 'fn', 'error': over});
    });

    test('a handler throw becomes a RuntimeError with error events', () {
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => throw StateError('no wand'),
          ),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      expect(
        entry.fn(const [MontyInt(1)], const {}),
        throwsA(
          isA<ExternalException>()
              .having((e) => e.excType, 'excType', 'RuntimeError')
              .having((e) => e.message, 'message', 'Bad state: no wand'),
        ),
      );
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallArgs 0 {"x":1}',
        'FunctionCallEnd 0',
        'FunctionCallResult 0 Error: Bad state: no wand',
        'CallFinished 0',
      ]);
      final [logged] = d.log.messages.where((m) => m.level == 'error').toList();
      expect(logged.message, 'Host handler error');
      expect(logged.error, 'Bad state: no wand');
      expect(logged.attributes, {
        'function': 'fn',
        'type': 'StateError',
      });
    });

    test("a handler's ExternalException is rethrown as itself", () {
      const boom = ExternalException('ValueError', 'bad wand');
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(
            schema: _xSchema,
            handler: (args, _) => throw boom,
          ),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      expect(
        entry.fn(const [MontyInt(1)], const {}),
        throwsA(same(boom)),
      );
      const refused = 'Error: ExternalException(ValueError, bad wand)';
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallArgs 0 {"x":1}',
        'FunctionCallEnd 0',
        'FunctionCallResult 0 $refused',
        'CallFinished 0',
      ]);
    });

    test('an unconvertible result emits the parity TypeError events', () async {
      const wand = _Wand();
      final d = fresh()
        ..dispatch.register(
          HostFunction.parity(schema: _xSchema, handler: (args, _) => wand),
        );
      final entry =
          d.dispatch.externals(
                d.events.add,
                os: null,
                cancelToken: null,
              )['fn']!
              as MontyHostFunction;

      // The dispatch layer records its TypeError and hands the raw value
      // back; the entry's own conversion then refuses it.
      await expectLater(
        entry.fn(const [MontyInt(1)], const {}),
        throwsA(isA<ArgumentError>()),
      );
      final hint =
          'Cannot convert ${wand.runtimeType} to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)';
      expect(d.events.map(_describe), [
        'CallStarted 0',
        'FunctionCallStart 0 fn',
        'FunctionCallArgs 0 {"x":1}',
        'FunctionCallEnd 0',
        'FunctionCallResult 0 TypeError: $hint',
        'CallFinished 0',
      ]);
      final [logged] = d.log.messages.where((m) => m.level == 'error').toList();
      expect(logged.message, 'Host result serialization error');
      expect(logged.error, 'TypeError: $hint');
      expect(logged.attributes, {
        'function': 'fn',
        'type': '${wand.runtimeType}',
        'errorType': 'ArgumentError',
      });
    });
  });
}
