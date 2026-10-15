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
  // When set, a checkout waits for it before it hands out a session.
  Completer<void>? checkoutGate;
  // When set, scripts each session as it is checked out.
  void Function(FakeMontySession session)? onCheckout;

  /// A checkout that hands out the next scripted session.
  Future<MontySession> checkout({ResourceLimits? limits}) async {
    await checkoutGate?.future;
    final session = FakeMontySession();
    onCheckout?.call(session);
    sessions.add(session);

    return session;
  }

  Future<MontyRuntime> start({
    bool sandbox = false,
    OsHandler? os,
    Map<String, OsHandler>? osHandlers,
    List<MontyExtension>? extensions,
  }) async {
    final runtime = await startRuntimeWith(
      checkout: checkout,
      closePool: () async => poolCloses++,
      os: os,
      osHandlers: osHandlers,
      extensions: extensions,
      sandbox: sandbox,
    );
    addTearDown(runtime.dispose);

    return runtime;
  }

  setUp(() {
    sessions = [];
    poolCloses = 0;
    checkoutGate = null;
    onCheckout = null;
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

    test('a second execute while the first is still attaching the '
        'extensions runs nothing', () async {
      final gate = Completer<void>();
      final slow = _SlowAttach(gate.future);
      final runtime = await start(extensions: [slow]);
      sessions.single.willReturn(const MontyInt(1));

      final first = runtime.execute('first');
      final second = runtime.execute('second');
      final refused = expectLater(
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

      await refused;
      expect(await first.result, const MontyInt(1));
      expect(sessions.single.feeds, ['first']);
      expect(slow.attaches, 1);
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
  group('construction', () {
    test('rejects both os and osHandlers', () {
      Never handler(String n, List<MontyValue> a, Map<String, MontyValue> k) =>
          throw const OsCallNotHandledException();

      expect(
        () => MontyRuntime.start(os: handler, osHandlers: {'os.': handler}),
        throwsA(isA<AssertionError>()),
      );
    });

    test('composes osHandlers by prefix', () async {
      final seen = <String>[];
      final runtime = await start(
        osHandlers: {
          'os.': (name, args, kwargs) {
            seen.add(name);

            return const MontyString('v');
          },
        },
      );
      sessions.single
        ..willCallOs('os.getenv', args: const [MontyString('A'), MontyNone()])
        ..willReturn(const MontyNone());

      await runtime.execute('a').result;

      expect(seen, ['os.getenv']);
    });
  });

  group('dispose', () {
    test('rethrows an extension onDispose error after releasing the session '
        'and the pool', () async {
      final runtime = await start(extensions: [_FailingDispose()]);

      await expectLater(runtime.dispose(), throwsStateError);

      expect(sessions.single.isClosed, isTrue);
      expect(poolCloses, 1);
      await runtime.dispose();
      expect(poolCloses, 1);
    });
  });

  group('races', () {
    test('dispose closes a running sandbox execution', () async {
      final runtime = await start(sandbox: true);
      final handle = runtime.execute('loop()');
      await Future<void>.delayed(Duration.zero);
      sessions.single.willHold(Completer<void>().future);
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(
        handle.result,
        throwsA(isA<MontyCrashedError>()),
      );

      await runtime.dispose();

      await failed;
      expect(sessions.single.isClosed, isTrue);
    });

    test(
      'a clearState checkout that completes after dispose is closed',
      () async {
        final runtime = await start();
        final gate = checkoutGate = Completer<void>();
        final clearing = runtime.clearState();
        await Future<void>.delayed(Duration.zero);
        await runtime.dispose();

        gate.complete();
        await expectLater(clearing, throwsStateError);

        expect(sessions, hasLength(2));
        expect(sessions.every((s) => s.isClosed), isTrue);
      },
    );

    test('concurrent clearState calls leak no session', () async {
      final runtime = await start();

      await Future.wait([runtime.clearState(), runtime.clearState()]);
      await runtime.dispose();

      expect(sessions, hasLength(3));
      expect(sessions.every((s) => s.isClosed), isTrue);
    });

    test('a paused events listener does not hold the result', () async {
      final runtime = await start();
      sessions.single.willReturn(const MontyInt(1));
      final handle = runtime.execute('1');
      final sub = handle.events.listen((_) {})..pause();
      addTearDown(sub.cancel);

      expect(
        await handle.result.timeout(const Duration(seconds: 5)),
        const MontyInt(1),
      );
      sessions.single.willReturn(const MontyInt(2));
      expect(
        await runtime.execute('2').result.timeout(const Duration(seconds: 5)),
        const MontyInt(2),
      );
    });

    test('an extension that fails registration takes no checkout', () async {
      await expectLater(
        start(
          extensions: [
            _SlowAttach(Future.value()),
            _SlowAttach(Future.value()),
          ],
        ),
        throwsStateError,
      );

      expect(sessions, isEmpty);
    });

    test('cancel settles an execution still waiting for its checkout, and '
        'closes the session when it arrives', () async {
      final runtime = await start(sandbox: true);
      final gate = checkoutGate = Completer<void>();
      final handle = runtime.execute('x');
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(handle.result, throwsStateError);

      await handle.cancel();
      await failed;

      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sessions.single.isClosed, isTrue);
    });

    test(
      'dispose settles an execution still waiting for its checkout',
      () async {
        final runtime = await start(sandbox: true);
        final gate = checkoutGate = Completer<void>();
        final handle = runtime.execute('x');
        await Future<void>.delayed(Duration.zero);
        final failed = expectLater(handle.result, throwsStateError);

        await runtime.dispose();
        await failed;
        gate.complete();
      },
    );

    test('a post-cancel checkout that loses to clearState is closed', () async {
      final runtime = await start();
      sessions.single.willHold(Completer<void>().future);
      final cancelled = runtime.execute('loop()');
      await Future<void>.delayed(Duration.zero);
      final crashed = expectLater(
        cancelled.result,
        throwsA(isA<MontyCrashedError>()),
      );
      await cancelled.cancel();
      await crashed;

      final gate = checkoutGate = Completer<void>();
      onCheckout = (s) => s.willReturn(const MontyInt(5));
      final next = runtime.execute('x');
      await Future<void>.delayed(Duration.zero);
      final clearing = runtime.clearState();
      await Future<void>.delayed(Duration.zero);
      gate.complete();

      await clearing;
      expect(await next.result, const MontyInt(5));
      await runtime.dispose();
      expect(sessions, hasLength(3));
      expect(sessions.every((s) => s.isClosed), isTrue);
    });

    test('dispose waits for an attachment in progress before disposing the '
        'extensions', () async {
      final gate = Completer<void>();
      final log = <String>[];
      final runtime = await start(extensions: [_Logged(gate.future, log)]);
      final outcome = runtime
          .execute('x')
          .result
          .then<Object?>(
            (_) => null,
            onError: (Object e) => e,
          );
      await Future<void>.delayed(Duration.zero);

      final disposing = runtime.dispose();
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await disposing;
      await outcome;

      expect(log, ['attach start', 'attach end', 'dispose']);
    });

    test('cancel settles an execution waiting for a clearState', () async {
      final runtime = await start();
      final gate = checkoutGate = Completer<void>();
      final clearing = runtime.clearState();
      final handle = runtime.execute('x');
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(handle.result, throwsStateError);

      await handle.cancel();
      await failed;

      gate.complete();
      await clearing;
    });

    test('dispose settles an execution waiting for a clearState', () async {
      final runtime = await start();
      final gate = checkoutGate = Completer<void>();
      final clearing = runtime.clearState().then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      final handle = runtime.execute('x');
      await Future<void>.delayed(Duration.zero);
      final failed = expectLater(handle.result, throwsStateError);

      await runtime.dispose();
      await failed;

      gate.complete();
      await clearing;
      expect(sessions.every((s) => s.isClosed), isTrue);
    });

    test('invoke during a clearState runs on the cleared runtime', () async {
      final runtime = await start()
        ..register(_echo);
      final gate = checkoutGate = Completer<void>();
      final clearing = runtime.clearState();
      // The old bridge is disposed; the new checkout waits on the gate.
      await Future<void>.delayed(Duration.zero);
      final invoked = runtime.invoke('echo', const {'value': 'v'});

      gate.complete();
      await clearing;

      expect(await invoked, 'v');
    });

    test(
      'execute and invoke on first use attach the extensions once',
      () async {
        final gate = Completer<void>();
        final slow = _SlowAttach(gate.future);
        final runtime = await start(extensions: [slow])
          ..register(_echo);
        sessions.single.willReturn(const MontyNone());

        final run = runtime.execute('x');
        final invoked = runtime.invoke('echo', const {'value': 'v'});
        gate.complete();

        expect(await invoked, 'v');
        await run.result;
        expect(slow.attaches, 1);
      },
    );
  });

  group('HostContext.parent', () {
    test("schemas are the runtime's", () async {
      List<String>? seen;
      final runtime = await start()
        ..register(_echo)
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(name: 'peek', description: ''),
            handler: (args, ctx) async {
              seen = ctx.parent!.schemas.map((s) => s.name).toList();

              return null;
            },
          ),
        );
      sessions.single
        ..willCall('peek')
        ..willReturn(const MontyNone());

      await runtime.execute('peek()').result;

      expect(seen, runtime.schemas.map((s) => s.name).toList());
      expect(seen, containsAll(['echo', 'peek']));
    });
  });
}

/// An extension whose `onAttach` waits for [gate].
final class _SlowAttach extends MontyExtension {
  _SlowAttach(this.gate);

  final Future<void> gate;
  int attaches = 0;

  @override
  String get namespace => 'slow';

  @override
  List<HostFunction> get functions => const [];

  @override
  Future<void> onAttach(AttachContext ctx) async {
    await super.onAttach(ctx);
    attaches++;
    await gate;
  }
}

/// An extension that logs its attach and dispose; attaching waits for
/// [gate].
final class _Logged extends MontyExtension {
  _Logged(this.gate, this.log);

  final Future<void> gate;
  final List<String> log;

  @override
  String get namespace => 'logged';

  @override
  List<HostFunction> get functions => const [];

  @override
  Future<void> onAttach(AttachContext ctx) async {
    await super.onAttach(ctx);
    log.add('attach start');
    await gate;
    log.add('attach end');
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    log.add('dispose');
  }
}

/// An extension whose `onDispose` throws.
final class _FailingDispose extends MontyExtension {
  @override
  String get namespace => 'failing';

  @override
  List<HostFunction> get functions => const [];

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    throw StateError('onDispose failed');
  }
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
