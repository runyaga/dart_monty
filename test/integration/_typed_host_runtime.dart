// Explicit float spelling documents numeric kind and signed zero.
// ignore_for_file: prefer_int_literals
/// Real worker witnesses for the typed host contract.
// ignore_for_file: prefer_const_constructors
// ignore_for_file: prefer_const_literals_to_create_immutables
// Fresh sentinel instances are the behavior under test.
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';
import '../src/_recording_session.dart';

/// Non-constant sentinels: a fresh equal value must not be identical.
MontyValue _sentinel(HostParamType type) => switch (type) {
  HostParamType.string => MontyString('owned'),
  HostParamType.integer => MontyInt(17),
  HostParamType.number => MontyFloat(-0.0),
  HostParamType.boolean => MontyBool(true),
  HostParamType.list => MontyList([MontyInt(17)]),
  HostParamType.map => MontyDict([(MontyInt(17), MontyNone())]),
  HostParamType.any => MontyTuple([MontyString('owned')]),
};

String _call(DispatchMode mode, String args) =>
    '${mode == DispatchMode.future ? 'await ' : ''}probe($args)';

/// A downstream BoundCall-style middleware adapter at the handler seam.
final class _BoundCall {
  _BoundCall(this.target);

  final HostFunctionHandler target;
  int entries = 0;

  Future<MontyValue> invoke(Map<String, MontyValue> args, HostContext context) {
    entries++;

    return target(args, context);
  }
}

/// Registers the real worker matrix in the contract suite.
void registerTypedHostRuntimeTests() {
  late Monty pool;
  setUp(() async {
    pool = await Monty.start(
      workerLocation: acceptanceWorkerLocation,
      maxProcesses: 3,
      checkoutTimeout: const Duration(seconds: 5),
    );
    addTearDown(pool.close);
  });

  Future<MontyRuntime> start({bool sandbox = false}) async {
    final runtime = await MontyRuntime.start(pool: pool, sandbox: sandbox);
    addTearDown(runtime.dispose);

    return runtime;
  }

  for (final type in HostParamType.values) {
    for (final mode in DispatchMode.values) {
      for (final explicitSlot in [false, true]) {
        test(
          'default values preserve identity for $type $mode '
          'explicit=$explicitSlot',
          () async {
            final runtime = await start();
            final sentinel = _sentinel(type);
            final seen = <MontyValue>[];
            Future<MontyValue> handler(
              Map<String, MontyValue> args,
              HostContext _,
            ) {
              final value = args['x']!;
              seen.add(value);

              return Future.value(MontyBool(identical(value, sentinel)));
            }

            runtime.register(
              HostFunction(
                schema: HostFunctionSchema(
                  name: 'probe',
                  params: [
                    HostParam(
                      name: 'x',
                      type: type,
                      isRequired: false,
                      defaultValue: sentinel,
                    ),
                  ],
                ),
                dispatch: mode,
                handler: explicitSlot
                    ? (_, _) => throw StateError('wrong slot')
                    : handler,
                ffiHandler: explicitSlot
                    ? (args, ctx) {
                        expect(hasWorkerProcesses, isTrue);

                        return handler(args, ctx);
                      }
                    : null,
                wasmHandler: explicitSlot
                    ? (args, ctx) {
                        expect(hasWorkerProcesses, isFalse);

                        return handler(args, ctx);
                      }
                    : null,
              ),
            );
            expect(
              await runtime.execute(_call(mode, '')).result,
              const MontyBool(true),
            );
            expect(identical(seen.last, sentinel), isTrue);
            expect(await runtime.invoke('probe', {}), const MontyBool(true));
            expect(seen.last, same(sentinel));
            expect(
              await runtime.execute(_call(mode, 'None')).result,
              const MontyBool(false),
            );
            expect(seen.last, isA<MontyNone>());
            expect(
              await runtime.invoke('probe', {'x': _sentinel(type)}),
              const MontyBool(false),
            );
            expect(
              await runtime
                  .execute(
                    _call(mode, 'value'),
                    inputs: {'value': _sentinel(type)},
                  )
                  .result,
              const MontyBool(false),
            );
          },
        );
      }
    }
  }

  for (final sandbox in [false, true]) {
    for (final mode in DispatchMode.values) {
      test(
        'cancel tokens are scoped to one execution sandbox=$sandbox $mode',
        () async {
          final runtime = await start(sandbox: sandbox);
          final tokens = <CancelToken>[];
          final key = Object();
          final marker = Object();
          runtime.register(
            HostFunction(
              schema: const HostFunctionSchema(name: 'probe'),
              dispatch: mode,
              handler: (_, ctx) async {
                expect(Zone.current[key], same(marker));
                tokens.add(ctx.cancelToken);

                return const MontyNone();
              },
            ),
          );
          final probeCall = _call(mode, '');
          for (var run = 0; run < 2; run++) {
            await runZoned(
              () => runtime.execute('$probeCall\n$probeCall').result,
              zoneValues: {key: marker},
            );
          }
          expect(tokens, hasLength(4));
          expect(identical(tokens.first, tokens[1]), isTrue);
          expect(identical(tokens[2], tokens[3]), isTrue);
          expect(identical(tokens.first, tokens[2]), isFalse);
        },
      );
    }
  }

  test(
    'shared mode recovers after concurrent cancellation',
    () async {
      final sessions = <RecordingSession>[];
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async {
          final session = RecordingSession(await pool.checkout(limits: limits));
          sessions.add(session);

          return session;
        },
      );
      addTearDown(runtime.dispose);
      final entered = Completer<void>();
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'probe'),
          handler: (_, ctx) async {
            entered.complete();
            await ctx.cancelToken.future;

            return const MontyNone();
          },
        ),
      );
      final first = runtime.execute('probe()');
      // Closing an active core session settles its feed with StateError.
      final failed = expectLater(first.result, throwsStateError);
      await entered.future;
      await expectLater(runtime.execute('2').result, throwsStateError);
      await first.cancel();
      await failed;
      expect(sessions.single.closed, isTrue);
      expect(await runtime.execute('42').result, const MontyInt(42));
    },
  );

  for (final mode in DispatchMode.values) {
    test('handler errors and validation failures propagate $mode', () async {
      final runtime = await start();
      final middleware = _BoundCall((args, _) async {
        if (args['x'] == const MontyInt(1)) throw StateError('ordinary');
        throw const ExternalException('ValueError', 'explicit');
      });
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'probe',
            params: [HostParam(name: 'x', type: HostParamType.integer)],
          ),
          dispatch: mode,
          handler: middleware.invoke,
        ),
      );
      for (final args in ['1.0', 'True', '', '1, 2', 'typo=1']) {
        await expectLater(
          runtime.execute(_call(mode, args)).result,
          throwsA(
            isA<MontyError>().having(
              (e) => e.exception.excType,
              'type',
              'RuntimeError',
            ),
          ),
        );
      }
      // A BoundCall adapter belongs inside the handler.
      // No middleware can observe invalid arguments.
      for (final args in [
        <String, MontyValue>{},
        {'x': const MontyFloat(1.0)},
        {'x': const MontyBool(true)},
        {'typo': const MontyInt(1)},
      ]) {
        await expectLater(runtime.invoke('probe', args), throwsFormatException);
      }
      expect(middleware.entries, 0);
      for (final (arg, error) in [('1', 'RuntimeError'), ('2', 'ValueError')]) {
        await expectLater(
          runtime.execute(_call(mode, arg)).result,
          throwsA(
            isA<MontyError>().having((e) => e.exception.excType, 'type', error),
          ),
        );
      }
      expect(middleware.entries, 2);
      expect(await runtime.execute('42').result, const MontyInt(42));
    });

    test('invalid handler returns are rejected $mode', () async {
      final runtime = await start();
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'probe'),
          dispatch: mode,
          // Simulate a dynamic application violating the typed return contract.
          handler: (_, _) async => (Object() as dynamic) as MontyValue,
        ),
      );
      await expectLater(
        runtime.execute(_call(mode, '')).result,
        throwsA(
          isA<MontyError>().having(
            (e) => e.exception.excType,
            'type',
            'RuntimeError',
          ),
        ),
      );
      expect(await runtime.execute('42').result, const MontyInt(42));
    });

    test('numeric values and dictionaries retain their kinds $mode', () async {
      final runtime = await start();
      final seen = <MontyValue>[];
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'probe',
            params: [HostParam(name: 'x', type: HostParamType.any)],
          ),
          dispatch: mode,
          handler: (args, _) async {
            seen.add(args['x']!);

            return args['x']!;
          },
        ),
      );
      for (final code in ['1', '1.0', '-0.0', '2 ** 100']) {
        await runtime.execute(_call(mode, code)).result;
      }
      final isMontyInt = isA<MontyInt>();
      expect(seen.first, isMontyInt);
      expect(seen[1], isA<MontyFloat>());
      expect((seen[2] as MontyFloat).value.isNegative, isTrue);
      expect((seen[3] as MontyBigInt).value, BigInt.one << 100);
      await runtime
          .execute(
            'child = {7: [1], (8, 9): -0.0}\n'
            '${_call(mode, '{1: child, (2, 3): child}')}',
          )
          .result;
      final pairs = (seen.last as MontyDict).pairs;
      expect(pairs.first.$1, isMontyInt);
      expect(pairs[1].$1, isA<MontyTuple>());
      expect(identical(pairs.first.$2, pairs[1].$2), isTrue);
    });
  }

  test('event dictionaries reach the event loop', () async {
    final eventLoop = EventLoopExtension();
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: [eventLoop],
    );
    addTearDown(runtime.dispose);
    const event = MontyDict([
      (MontyTuple([MontyInt(1)]), MontyString('event')),
    ]);
    eventLoop.dispatch(event);
    await runtime.execute('await el_emit(await el_recv())').result;
    expect(eventLoop.lastEmitted, event);
    expect(eventLoop.lastEmittedSignal.value, same(eventLoop.lastEmitted));
  });

  test('runScript is registered under its schema key', () async {
    final runtime = await start();
    runtime.register(buildRunScriptFunction((_) => '42'));
    for (final inputs in [
      '{1: 1}',
      "{'1': 1}",
      "{'not a name': 1}",
      "{'for': 1}",
    ]) {
      await expectLater(
        runtime.execute("run_script('child.py', inputs=$inputs)").result,
        throwsA(
          isA<MontyError>().having(
            (e) => e.exception.message,
            'message',
            contains('variable names'),
          ),
        ),
      );
    }
    expect(
      await runtime
          .execute("run_script('child.py', inputs={'valid_name': 1})")
          .result,
      const MontyInt(42),
    );
  });
}
