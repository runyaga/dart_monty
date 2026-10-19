// MontyBridge over a real worker session: run events, print collection,
// Python failures and the OS-call rules (D1-2); host calls (D1-3).
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

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

  test('a run collects print output and ends with its value', () async {
    final events = await bridge
        .execute('print("hello")\nprint("world")\n6 * 7')
        .toList();

    expect(events.first, isA<BridgeRunStarted>());
    final finished = events.last as BridgeRunFinished;
    expect(finished.value, 42);
    expect(finished.montyValue, const MontyInt(42));
    expect(finished.printOutput, 'hello\nworld\n');
  });

  test('a Python exception ends the run with BridgeRunError', () async {
    final events = await bridge
        .execute('print("before")\nraise ValueError("boom")')
        .toList();

    final error = events.last as BridgeRunError;
    expect(events.whereType<BridgeRunError>(), hasLength(1));
    expect(error.exception, isA<MontyRuntimeError>());
    expect(error.message, 'ValueError: boom');
    expect(error.printOutput, 'before\n');
  });

  test('a syntax error ends the run with MontySyntaxError', () async {
    final events = await bridge.execute('def (').toList();

    expect(
      events.whereType<BridgeRunError>().single.exception,
      isA<MontySyntaxError>(),
    );
  });

  test('a type-check rejection ends the run with MontyTypingError', () async {
    final checked = await pool.checkout(typeCheck: true);
    addTearDown(checked.close);
    final b = MontyBridge(session: checked, logger: BridgeLogger.silent);
    addTearDown(b.dispose);

    final events = await b.execute('x: int = "not an int"').toList();

    expect(
      events.whereType<BridgeRunError>().single.exception,
      isA<MontyTypingError>(),
    );
  });

  test('with no OS handler a filesystem call takes the worker default', () {
    return expectLater(
      _caught(bridge, "open('/nope.txt').read()"),
      completion(startsWith('PermissionError')),
    );
  });

  test('with no OS handler a non-filesystem call raises RuntimeError and '
      'emits no events', () async {
    final events = await bridge
        .execute(_tryCatch('os.getenv("HOME")'))
        .toList();

    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
    expect(events.whereType<BridgeOsCallResult>(), isEmpty);
    expect(
      (events.last as BridgeRunFinished).value,
      allOf(startsWith('RuntimeError'), contains('not supported')),
    );
  });

  test('a declining handler yields the worker default and Declined', () async {
    bridge.registerOs(
      (name, args, kwargs) => throw const OsCallNotHandledException(),
    );

    final events = await bridge
        .execute(_tryCatch("open('/nope.txt').read()"))
        .toList();

    expect(
      (events.last as BridgeRunFinished).value,
      allOf(startsWith('PermissionError'), contains('/nope.txt')),
    );
    expect(events.whereType<BridgeOsCallResult>().single.result, 'Declined');
  });

  test(
    'a declined non-filesystem call raises the worker RuntimeError',
    () async {
      bridge.registerOs(
        (name, args, kwargs) => throw const OsCallNotHandledException(),
      );

      final events = await bridge
          .execute(_tryCatch('os.getenv("HOME")'))
          .toList();

      expect(
        (events.last as BridgeRunFinished).value,
        allOf(
          startsWith('RuntimeError'),
          contains('is not supported in this environment'),
        ),
      );
      expect(events.whereType<BridgeOsCallResult>().single.result, 'Declined');
    },
  );

  test('a host handler answers and its call is reported', () async {
    bridge.registerOs((name, args, kwargs) {
      if (name == 'os.getenv') return const MontyString('from-host');
      throw const OsCallNotHandledException();
    });

    final events = await bridge
        .execute('import os\nos.getenv("APP_ENV")')
        .toList();

    expect((events.last as BridgeRunFinished).value, 'from-host');
    final start = events.whereType<BridgeOsCallStart>().single;
    expect(start.operationName, 'os.getenv');
    final result = events.whereType<BridgeOsCallResult>().single;
    expect(result.callId, start.callId);
    expect(result.result, 'from-host');
    expect(result.durationMs, isNotNull);
  });

  test('a handler ExternalException is raised as its Python type', () async {
    bridge.registerOs(
      (name, args, kwargs) =>
          throw const ExternalException('FileNotFoundError', 'gone'),
    );

    final events = await bridge
        .execute(_tryCatch("open('/x.txt').read()"))
        .toList();

    expect((events.last as BridgeRunFinished).value, 'FileNotFoundError: gone');
    expect(
      events.whereType<BridgeOsCallResult>().single.result,
      'Error: gone',
    );
  });

  test('calls the worker answers itself never reach the handler', () async {
    var reached = 0;
    bridge.registerOs((name, args, kwargs) {
      reached++;
      throw const OsCallNotHandledException();
    });

    // The default OsPolicy answers the clock and time.sleep in the worker.
    final sw = Stopwatch()..start();
    final events = await bridge
        .execute(
          'import datetime, time\n'
          'time.sleep(0.05)\n'
          'datetime.datetime.now().year > 2000',
        )
        .toList();
    sw.stop();

    expect((events.last as BridgeRunFinished).value, isTrue);
    expect(reached, 0);
    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
    // The session waited the sleep itself.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(50));
  });

  group('host calls', () {
    HostFunction fn(
      String name,
      HostFunctionHandler handler, {
      DispatchMode dispatch = DispatchMode.sync,
    }) => HostFunction(
      schema: HostFunctionSchema(
        name: name,
        description: '',
        params: const [HostParam(name: 'x', type: HostParamType.integer)],
      ),
      handler: handler,
      dispatch: dispatch,
    );

    Future<Object?> run(String code) async {
      final events = await bridge.execute(code).toList();
      final last = events.last;
      if (last is BridgeRunError) fail('run failed: ${last.message}');

      return (last as BridgeRunFinished).value;
    }

    test('a sync-mode call returns its value at the call site, with its '
        'events', () async {
      bridge.register(
        fn(
          'inc',
          (args, _) async =>
              MontyValue.fromDart(((args['x']! as MontyInt).value) + 1),
        ),
      );

      final events = await bridge.execute('inc(x=20) * 2').toList();

      expect((events.last as BridgeRunFinished).value, 42);
      expect(
        [
          for (final e in events)
            if (e is! BridgeRunStarted && e is! BridgeRunFinished)
              e.runtimeType,
        ],
        [
          BridgeCallStarted,
          BridgeFunctionCallStart,
          BridgeFunctionCallArgs,
          BridgeFunctionCallEnd,
          BridgeFunctionCallResult,
          BridgeCallFinished,
        ],
      );
    });

    test('a result reaches Python through MontyValue.fromDart', () async {
      bridge.register(
        fn(
          'data',
          (_, _) async => MontyValue.fromDart({
            'a': [1, 2.5, null, true],
          }),
        ),
      );

      expect(
        await run('d = data(x=0)\n[type(d).__name__, d["a"][1], d["a"][2]]'),
        ['dict', 2.5, null],
      );
    });

    test('future-mode calls run concurrently under asyncio.gather', () async {
      // Each handler waits until all three have started: run one at a time
      // they would never finish (the test times out).
      var started = 0;
      final allStarted = Completer<void>();
      bridge.register(
        fn('slow', (args, _) async {
          if (++started == 3) allStarted.complete();
          await allStarted.future;

          return args['x']!;
        }, dispatch: DispatchMode.future),
      );

      final value = await run(
        'import asyncio\n'
        'await asyncio.gather(slow(x=1), slow(x=2), slow(x=3))',
      );

      expect(value, [1, 2, 3]);
      expect(started, 3);
    });

    test('arguments whose JSON would be huge are shown as a note, and the '
        'call goes on', () async {
      // 31 distinct lists, each shared twice by the next: about 2^30 lists
      // once expanded.
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'take',
            description: '',
            params: [HostParam(name: 'v', type: HostParamType.list)],
          ),
          handler: (_, _) async => const MontyString('ran'),
        ),
      );

      final events = await bridge
          .execute('x = []\nfor _ in range(30):\n    x = [x, x]\ntake(x)')
          .toList();

      expect((events.last as BridgeRunFinished).value, 'ran');
      expect(
        events.whereType<BridgeFunctionCallArgs>().single.delta,
        startsWith('"arguments not shown: over '),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a result whose text would be huge is cut, and Python gets the '
        'value', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'echo',
            description: '',
            params: [HostParam(name: 'v', type: HostParamType.list)],
          ),
          handler: (args, _) async => args['v']!,
        ),
      );

      final events = await bridge
          .execute('x = []\nfor _ in range(30):\n    x = [x, x]\nlen(echo(x))')
          .toList();

      expect((events.last as BridgeRunFinished).value, 2);
      expect(
        events.whereType<BridgeFunctionCallResult>().single.result,
        endsWith('... (cut at 1048576 characters)'),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('a thrown value whose text would be huge is cut in the event and '
        'the Python exception', () async {
      bridge.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'throw_back',
            description: '',
            params: [HostParam(name: 'v', type: HostParamType.list)],
          ),
          // ignore: only_throw_errors – a thrown value, as a handler may.
          handler: (args, _) async => throw args['v']!,
        ),
      );

      final events = await bridge
          .execute(
            'x = []\nfor _ in range(30):\n    x = [x, x]\n'
            'try:\n    throw_back(x)\n    out = "none"\n'
            'except RuntimeError as e:\n    out = str(e)[-40:]\nout',
          )
          .toList();

      expect(
        (events.last as BridgeRunFinished).value,
        endsWith('(cut at 1048576 characters)'),
      );
      expect(
        events.whereType<BridgeFunctionCallResult>().single.result,
        allOf(
          startsWith('Error: [[['),
          endsWith('(cut at 1048576 characters)'),
        ),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('asyncio.sleep runs alongside a future-mode call', () async {
      bridge.register(
        fn('later', (args, _) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));

          return args['x']!;
        }, dispatch: DispatchMode.future),
      );

      expect(
        await run(
          'import asyncio\n'
          'await asyncio.gather(asyncio.sleep(0.01), later(x=5))',
        ),
        [null, 5],
      );
    });

    test('an unknown name raises NameError and emits no call events', () async {
      final events = await bridge.execute('not_registered(x=1)').toList();

      expect(events.whereType<BridgeCallStarted>(), isEmpty);
      final error = events.whereType<BridgeRunError>().single;
      expect(error.exception?.exception.excType, 'NameError');
    });

    test('a function with no handler on this backend is a NameError', () async {
      bridge.register(
        const HostFunction(
          schema: HostFunctionSchema(name: 'absent', description: ''),
        ),
      );

      expect(
        await _caught(bridge, 'absent()'),
        startsWith('NameError: '),
      );
    });

    test('a handler throw is a RuntimeError Python catches at the call '
        'site', () async {
      bridge.register(fn('boom', (_, _) async => throw StateError('kaboom')));

      expect(
        await _caught(bridge, 'boom(x=1)'),
        'RuntimeError: Bad state: kaboom',
      );
    });

    test('a validation failure is a RuntimeError with its message', () async {
      var called = false;
      bridge.register(
        fn('need', (_, _) async {
          called = true;

          return const MontyNone();
        }),
      );

      expect(
        await _caught(bridge, 'need()'),
        allOf(
          startsWith('RuntimeError: '),
          contains('Required parameter "x" is missing'),
        ),
      );
      expect(called, isFalse);
    });

    test("a handler's own ExternalException selects the Python type", () async {
      bridge.register(
        fn(
          'picky',
          (_, _) async => throw const ExternalException('ValueError', 'no'),
        ),
      );

      expect(await _caught(bridge, 'picky(x=1)'), 'ValueError: no');
    });

    test('a future-mode failure is raised where Python awaits it', () async {
      bridge.register(
        fn(
          'later_boom',
          (_, _) async => throw StateError('late'),
          dispatch: DispatchMode.future,
        ),
      );

      expect(
        await run(
          't = later_boom(x=1)\n'
          'out = "not raised at the call"\n'
          'try:\n'
          '    await t\n'
          'except RuntimeError as e:\n'
          '    out = out + "; " + str(e)\n'
          'out',
        ),
        'not raised at the call; Bad state: late',
      );
    });
  });
}

/// [expr] run in a try block; the run's value is `'<type>: <message>'` of
/// what it raised.
String _tryCatch(String expr) =>
    '''
import os
try:
    $expr
    out = 'NO EXCEPTION RAISED'
except Exception as e:
    out = type(e).__name__ + ': ' + str(e)
out
''';

/// The `'<type>: <message>'` of what [expr] raises on [bridge].
Future<String> _caught(MontyBridge bridge, String expr) async {
  final events = await bridge.execute(_tryCatch(expr)).toList();

  return (events.last as BridgeRunFinished).value! as String;
}
