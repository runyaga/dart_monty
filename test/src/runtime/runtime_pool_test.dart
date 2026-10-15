import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/runtime/runtime.dart'
    show defaultPoolSize, startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

/// Tests of how `MontyRuntime` uses its sessions: which it checks out, when
/// it closes them, and how cancel closes a busy one. The sessions are
/// core's scripted `FakeMontySession`s, supplied through the runtime's
/// test hook.
void main() {
  late List<FakeMontySession> sessions;
  late int poolCloses;

  /// A checkout that hands out the next scripted session.
  Future<MontySession> checkout({ResourceLimits? limits}) async {
    final session = FakeMontySession();
    sessions.add(session);

    return session;
  }

  Future<MontyRuntime> start({
    bool sandbox = false,
    OsHandler? os,
    List<MontyExtension>? extensions,
  }) async {
    final runtime = await startRuntimeWith(
      checkout: checkout,
      closePool: () async => poolCloses++,
      os: os,
      extensions: extensions,
      sandbox: sandbox,
    );
    addTearDown(runtime.dispose);

    return runtime;
  }

  setUp(() {
    sessions = [];
    poolCloses = 0;
  });

  group('default pool', () {
    test('has room for a root, a sub-execution and no children', () {
      expect(defaultPoolSize(null), 2);
      expect(defaultPoolSize(const []), 2);
    });

    test("has room for the SandboxExtension's maxChildren", () {
      expect(defaultPoolSize([SandboxExtension(maxChildren: 5)]), 7);
      expect(defaultPoolSize([SandboxExtension()]), 18);
    });

    test('checkoutTimeout is 30 seconds', () {
      expect(MontyRuntime.defaultCheckoutTimeout, const Duration(seconds: 30));
    });
  });

  group('shared mode', () {
    test('holds one checkout from start, and runs every feed on it', () async {
      final runtime = await start();
      expect(sessions, hasLength(1));

      sessions.single.willReturn(const MontyInt(1));
      await runtime.execute('a').result;
      sessions.single.willReturn(const MontyInt(2));
      final value = await runtime.execute('b').result;

      expect(value, const MontyInt(2));
      expect(sessions, hasLength(1));
      expect(sessions.single.feeds, ['a', 'b']);
      expect(sessions.single.isClosed, isFalse);
    });

    test('inputs go to the feed, not into the code', () async {
      final runtime = await start();
      sessions.single.willReturn(const MontyNone());

      await runtime.execute('x', inputs: {'x': 1}).result;

      expect(sessions.single.feeds, ['x']);
    });

    test('dispose closes the held session and the pool, once', () async {
      final runtime = await start();

      await runtime.dispose();
      await runtime.dispose();

      expect(sessions.single.isClosed, isTrue);
      expect(poolCloses, 1);
    });

    test('clearState closes the held session and checks out another', () async {
      final runtime = await start();
      final first = sessions.single;

      await runtime.clearState();

      expect(first.isClosed, isTrue);
      expect(sessions, hasLength(2));
      sessions.last.willReturn(const MontyInt(3));
      expect(await runtime.execute('y').result, const MontyInt(3));
      expect(first.feeds, isEmpty);
      expect(sessions.last.feeds, ['y']);
    });

    test('a second execute while one runs runs nothing', () async {
      final runtime = await start();
      final gate = Completer<void>();
      sessions.single
        ..willHold(gate.future)
        ..willReturn(const MontyInt(1));

      final first = runtime.execute('first');
      final second = runtime.execute('second');

      await expectLater(
        second.result,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Bridge is already executing',
          ),
        ),
      );
      gate.complete();
      expect(await first.result, const MontyInt(1));
      expect(sessions.single.feeds, ['first']);
    });

    test('invoke runs no Python', () async {
      final runtime = await start()
        ..register(_echo);

      expect(await runtime.invoke('echo', const {'value': 'hi'}), 'hi');
      expect(sessions.single.feeds, isEmpty);
    });
  });

  group('sandbox mode', () {
    test('starts with no checkout', () async {
      await start(sandbox: true);

      expect(sessions, isEmpty);
    });

    test('each execute checks out its own session and closes it', () async {
      final runtime = await start(sandbox: true);
      final first = runtime.execute('a');
      await Future<void>.delayed(Duration.zero);
      sessions.last.willReturn(const MontyInt(1));
      await first.result;
      final second = runtime.execute('b');
      await Future<void>.delayed(Duration.zero);
      sessions.last.willReturn(const MontyInt(2));

      expect(await second.result, const MontyInt(2));
      expect(sessions, hasLength(2));
      expect(sessions.map((s) => s.feeds), [
        ['a'],
        ['b'],
      ]);
      expect(sessions.every((s) => s.isClosed), isTrue);
    });

    test('a function registered after start reaches later executions, and '
        'schemas stay empty', () async {
      final runtime = await start(sandbox: true)
        ..register(_echo);

      expect(runtime.schemas, isEmpty);
      final handle = runtime.execute('echo("v")');
      await Future<void>.delayed(Duration.zero);
      sessions.single
        ..willCall('echo', args: const [MontyString('v')])
        ..willReturn(const MontyNone());
      await handle.result;

      expect(
        sessions.single.answers.single.answer,
        isA<ExternalReturnValue>().having(
          (r) => r.value,
          'value',
          const MontyString('v'),
        ),
      );
    });

    test('dispose closes the pool and checks out nothing', () async {
      final runtime = await start(sandbox: true);

      await runtime.dispose();

      expect(sessions, isEmpty);
      expect(poolCloses, 1);
    });
  });

  group('execute(os:)', () {
    test('overrides the OS handler for one feed only', () async {
      final seen = <String>[];
      OsHandler handler(String tag) => (name, args, kwargs) {
        seen.add(tag);

        return const MontyString('v');
      };
      final runtime = await start(os: handler('runtime'));

      sessions.single
        ..willCallOs('os.getenv', args: const [MontyString('A'), MontyNone()])
        ..willReturn(const MontyNone());
      await runtime.execute('a', os: handler('override')).result;
      sessions.single
        ..willCallOs('os.getenv', args: const [MontyString('A'), MontyNone()])
        ..willReturn(const MontyNone());
      await runtime.execute('b').result;

      expect(seen, ['override', 'runtime']);
    });
  });

  group('cancel', () {
    test('during a turn kills the worker: MontyCrashedError, and the next '
        'execute runs on a fresh checkout', () async {
      final runtime = await start();
      final held = sessions.single..willHold(Completer<void>().future);

      final handle = runtime.execute('loop()');
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(
        handle.result,
        throwsA(isA<MontyCrashedError>()),
      );
      await handle.cancel();

      await failed;
      expect(held.isClosed, isTrue);

      final next = runtime.execute('x');
      await Future<void>.delayed(Duration.zero);
      expect(sessions, hasLength(2));
      sessions.last.willReturn(const MontyInt(7));
      expect(await next.result, const MontyInt(7));
      expect(sessions.last.feeds, ['x']);
    });

    test('during a host callback fails the call at once; the callback runs '
        'on and its late result is dropped', () async {
      final release = Completer<void>();
      final entered = Completer<CancelToken>();
      var finished = false;
      final runtime = await start()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'slow', description: ''),
            handler: (args, ctx) async {
              entered.complete(ctx.cancelToken);
              await release.future;
              finished = true;

              return 'late';
            },
          ),
        );
      sessions.single
        ..willCall('slow')
        ..willReturn(const MontyNone());

      final handle = runtime.execute('slow()');
      final token = await entered.future;
      final failed = expectLater(handle.result, throwsA(isA<StateError>()));
      await handle.cancel();

      await failed;
      expect(token.isCancelled, isTrue);
      expect(sessions.single.isClosed, isTrue);
      expect(finished, isFalse);

      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(finished, isTrue);
    });

    test('in sandbox mode closes the execution checkout', () async {
      final runtime = await start(sandbox: true);
      final handle = runtime.execute('loop()');
      await Future<void>.delayed(Duration.zero);
      sessions.single.willHold(Completer<void>().future);
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(
        handle.result,
        throwsA(isA<MontyCrashedError>()),
      );

      await handle.cancel();

      await failed;
      expect(sessions.single.isClosed, isTrue);
    });

    test('after the execution finished does nothing: the held session '
        'stays open and runs the next feed', () async {
      final runtime = await start();
      sessions.single.willReturn(const MontyInt(1));
      final handle = runtime.execute('x = 1');
      await handle.result;

      await handle.cancel();

      expect(sessions.single.isClosed, isFalse);
      sessions.single.willReturn(const MontyInt(1));
      await runtime.execute('x').result;
      expect(sessions, hasLength(1));
      expect(sessions.single.feeds, ['x = 1', 'x']);
    });

    test('is idempotent and does not throw', () async {
      final runtime = await start();
      sessions.single.willHold(Completer<void>().future);
      final handle = runtime.execute('loop()');
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(
        handle.result,
        throwsA(isA<MontyCrashedError>()),
      );

      await handle.cancel();
      await handle.cancel();

      await failed;
      await handle.cancel();
    });
  });
}

/// A host function that returns its `value` argument.
final _echo = HostFunction(
  schema: const HostFunctionSchema(
    name: 'echo',
    description: '',
    params: [HostParam(name: 'value', type: HostParamType.string)],
  ),
  handler: (args, _) async => args['value'],
);
