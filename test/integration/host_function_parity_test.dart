@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

class Opaque {
  const Opaque();
}

void main() {
  late Monty pool;
  late MontySession session;
  late MontyBridge bridge;

  setUpAll(() async {
    pool = await startTestPool();
  });

  tearDownAll(() async {
    await pool.close();
  });

  setUp(() async {
    session = await pool.checkout();
    bridge = MontyBridge(session: session, logger: BridgeLogger.silent);
  });

  tearDown(() async {
    bridge.dispose();
    await session.close();
  });

  Future<BridgeRunError> expectRunError(String code) async {
    final events = await bridge.execute(code).toList();
    final errors = events.whereType<BridgeRunError>().toList();
    expect(errors, hasLength(1));

    return errors.firstOrNull!;
  }

  Future<BridgeRunFinished> expectRunFinished(String code) async {
    final events = await bridge.execute(code).toList();
    final finished = events.whereType<BridgeRunFinished>().toList();
    expect(finished, hasLength(1));

    return finished.firstOrNull!;
  }

  test(
    'opaque Object() return through HostFunction.parity raises TypeError '
    'uncaught and can be caught as TypeError in Python',
    () async {
      const expectedMessage =
          'Cannot convert builtins.object to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)';
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(name: 'f'),
          handler: (_, _) => Object(),
        ),
      );

      final err = await expectRunError('f()');
      expect(err.exception, isA<MontyRuntimeError>());
      final pyException = err.exception!.exception;
      expect(pyException.excType, 'TypeError');
      expect(pyException.message, expectedMessage);
      expect(err.message, 'TypeError: $expectedMessage');

      final caught = await expectRunFinished('''
try:
    f()
except TypeError as e:
    r = str(e)
r
''');
      expect(caught.value, expectedMessage);
    },
  );

  test(
    'custom Opaque return through HostFunction.parity raises TypeError with '
    'Dart runtimeType',
    () async {
      const expectedMessage =
          'Cannot convert Opaque to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)';
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(name: 'opaque'),
          handler: (_, _) => const Opaque(),
        ),
      );

      final err = await expectRunError('opaque()');
      expect(err.exception, isA<MontyRuntimeError>());
      final runtimeErr = err.exception!;
      expect(runtimeErr.exception.excType, 'TypeError');
      expect(runtimeErr.exception.message, expectedMessage);
      expect(runtimeErr.toString(), 'TypeError: $expectedMessage');
    },
  );

  test(
    'direct invokeHostFunction on HostFunction.parity throws '
    'ExternalException(TypeError) matching Python and event text',
    () async {
      const expectedMessage =
          'Cannot convert builtins.object to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)';
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(name: 'f'),
          handler: (_, _) => Object(),
        ),
      );

      final events = await bridge.execute('f()').toList();
      final hasOneItem = hasLength(1);
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasOneItem);
      final pyErr = errors.firstOrNull!;

      final callResults = events.whereType<BridgeFunctionCallResult>().toList();
      expect(callResults, hasOneItem);
      final callResult = callResults.firstOrNull!;

      ExternalException? directErr;
      try {
        await bridge.invokeHostFunction('f', const {});
      } on ExternalException catch (e) {
        directErr = e;
      }

      expect(directErr, isNotNull);
      expect(directErr!.excType, 'TypeError');
      expect(directErr.message, expectedMessage);
      expect(directErr.message, pyErr.exception!.exception.message);
      expect(callResult.result, 'TypeError: $expectedMessage');
      expect(callResult.result, pyErr.message);
    },
  );

  test('null return from HostFunction.parity gives Python None', () async {
    bridge.register(
      HostFunction.parity(
        schema: const HostFunctionSchema(name: 'f'),
        handler: (_, _) => null,
      ),
    );

    final finished = await expectRunFinished('f() is None');
    expect(finished.montyValue, const MontyBool(true));

    final direct = await bridge.invokeHostFunction('f', const {});
    expect(direct, const MontyNone());
  });

  test(
    'x66_02: fetch_item with x and tag params raises PermissionError: '
    'denied-20 on line 2',
    () async {
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(
            name: 'fetch_item',
            params: [
              HostParam(name: 'x', type: HostParamType.integer),
              HostParam(name: 'tag', type: HostParamType.string),
            ],
          ),
          handler: (args, _) {
            final x = (args['x']! as MontyInt).value;
            if (x == 10) return 'ok-10';
            throw const ExternalException('PermissionError', 'denied-20');
          },
        ),
      );

      final err = await expectRunError('''
first = fetch_item(10, tag='first')
fetch_item(20, tag='second')
''');
      final runtimeErr = err.exception! as MontyRuntimeError;
      expect(runtimeErr.exception.excType, 'PermissionError');
      expect(runtimeErr.exception.message, 'denied-20');
      expect(err.message, 'PermissionError: denied-20');
      expect(runtimeErr.traceback.map((frame) => frame.line), [2]);
      expect(err.displayMessage, contains('line 2'));
      expect(err.displayMessage, contains('PermissionError: denied-20'));
    },
  );

  test(
    'x66_02 without tag parameter registered raises TypeError for unexpected '
    'keyword argument',
    () async {
      const expectedMessage =
          "fetch_item() got an unexpected keyword argument 'tag'";
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(
            name: 'fetch_item',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          handler: (_, _) => 'ok',
        ),
      );

      final err = await expectRunError("fetch_item(10, tag='first')");
      expect(err.exception, isA<MontyRuntimeError>());
      final runtimeErr = err.exception!;
      expect(runtimeErr.exception.excType, 'TypeError');
      expect(runtimeErr.exception.message, expectedMessage);
      expect(runtimeErr.toString(), 'TypeError: $expectedMessage');

      final caught = await expectRunFinished('''
try:
    fetch_item(10, tag='first')
except TypeError as e:
    r = str(e)
r
''');
      expect(caught.value, expectedMessage);
    },
  );

  test(
    'missing 1, 2, and 3 required positional arguments and too many '
    'positional arguments raise catchable Python TypeError',
    () async {
      bridge
        ..register(
          HostFunction.parity(
            schema: const HostFunctionSchema(name: 'zero'),
            handler: (_, _) => 0,
          ),
        )
        ..register(
          HostFunction.parity(
            schema: const HostFunctionSchema(
              name: 'one',
              params: [HostParam(name: 'a', type: HostParamType.integer)],
            ),
            handler: (_, _) => 1,
          ),
        )
        ..register(
          HostFunction.parity(
            schema: const HostFunctionSchema(
              name: 'two',
              params: [
                HostParam(name: 'a', type: HostParamType.integer),
                HostParam(name: 'b', type: HostParamType.integer),
              ],
            ),
            handler: (_, _) => 2,
          ),
        )
        ..register(
          HostFunction.parity(
            schema: const HostFunctionSchema(
              name: 'three',
              params: [
                HostParam(name: 'a', type: HostParamType.integer),
                HostParam(name: 'b', type: HostParamType.integer),
                HostParam(name: 'c', type: HostParamType.integer),
              ],
            ),
            handler: (_, _) => 3,
          ),
        );

      const cases = [
        ('two(1)', "two() missing 1 required positional argument: 'b'"),
        (
          'two()',
          "two() missing 2 required positional arguments: 'a' and 'b'",
        ),
        (
          'three()',
          "three() missing 3 required positional arguments: 'a', 'b', and 'c'",
        ),
        (
          'two(1, 2, 3)',
          'two() takes 2 positional arguments but 3 were given',
        ),
        (
          'one(1, 2)',
          'one() takes 1 positional argument but 2 were given',
        ),
        (
          'zero(1)',
          'zero() takes 0 positional arguments but 1 was given',
        ),
      ];

      for (final (call, expectedMessage) in cases) {
        final err = await expectRunError(call);
        expect(err.exception, isA<MontyRuntimeError>(), reason: call);
        final pyException = err.exception!.exception;
        expect(
          pyException.excType,
          'TypeError',
          reason: call,
        );
        expect(
          pyException.message,
          expectedMessage,
          reason: call,
        );

        final caught = await expectRunFinished('''
try:
    $call
except TypeError as e:
    r = str(e)
r
''');
        expect(caught.value, expectedMessage, reason: call);
      }
    },
  );

  test(
    'schema type mismatch on a parity function stays RuntimeError',
    () async {
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(
            name: 'two',
            params: [
              HostParam(name: 'a', type: HostParamType.integer),
              HostParam(name: 'b', type: HostParamType.integer),
            ],
          ),
          handler: (_, _) => 0,
        ),
      );

      final err = await expectRunError("two('bad', 2)");
      expect(err.exception, isA<MontyRuntimeError>());
      final pyException = err.exception!.exception;
      expect(pyException.excType, 'RuntimeError');
      expect(
        pyException.message,
        'FormatException: Parameter "a": expected integer, got MontyString',
      );
    },
  );

  test('D-1 legacy binder', () async {
    bridge.register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'fetch_item',
          params: [HostParam(name: 'x', type: HostParamType.integer)],
        ),
        handler: (_, _) async => const MontyString('ok'),
      ),
    );

    final err = await expectRunError("fetch_item(10, tag='first')");
    expect(err.exception, isA<MontyRuntimeError>());
    final pyException = err.exception!.exception;
    expect(pyException.excType, 'RuntimeError');
    expect(
      pyException.message,
      'FormatException: fetch_item: unknown keyword argument "tag"',
    );
  });

  test(
    'DispatchMode.future parity function returning an opaque value gives '
    'TypeError',
    () async {
      const expectedMessage =
          'Cannot convert builtins.object to Monty value — '
          'wrap class instances in pydantic_monty.ClassInstance(...)';
      bridge.register(
        HostFunction.parity(
          schema: const HostFunctionSchema(name: 'async_opaque'),
          dispatch: DispatchMode.future,
          handler: (_, _) async => Object(),
        ),
      );

      final err = await expectRunError('await async_opaque()');
      expect(err.exception, isA<MontyRuntimeError>());
      final pyException = err.exception!.exception;
      expect(pyException.excType, 'TypeError');
      expect(pyException.message, expectedMessage);

      final caught = await expectRunFinished('''
try:
    await async_opaque()
except TypeError as e:
    r = str(e)
r
''');
      expect(caught.value, expectedMessage);
    },
  );
}
