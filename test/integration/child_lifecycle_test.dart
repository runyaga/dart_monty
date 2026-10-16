// Keep guest programs and historical case IDs intact.
// ignore_for_file: lines_longer_than_80_chars
// Collection access fails fast when an expected session is missing.
// Fresh calls and repeated probes are deliberate lifecycle assertions.
// ignore_for_file: avoid-unsafe-collection-methods, prefer-moving-to-variable
// Private seam witnesses use core's public fake sessions; real transfers run below.
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../src/_recording_session.dart';
import '../src/_throwing_session.dart';
import '_child_contract.dart';

void main() {
  for (final providerFirst in [false, true]) {
    test('D5-parent-dispose-collection providerFirst=$providerFirst', () async {
      final provider = _CollectionProvider();
      final sandbox = SandboxExtension();
      final runtime = await MontyRuntime.start(
        pool: await childContractPool(),
        extensions: providerFirst ? [provider, sandbox] : [sandbox, provider],
      );
      addTearDown(runtime.dispose);
      addTearDown(provider.releaseWrite);
      final handle = await spawnChild(
        runtime,
        "from pathlib import Path; Path('output').write_text('done'); 42",
      );
      expect(await awaitChild(runtime, handle), const MontyInt(42));
      final collecting = expectLater(
        runtime.invoke('sandbox_await', {
          'handle': handle,
          'collect': const MontyDict([
            (MontyString('output'), MontyString('/parent/result')),
          ]),
        }),
        completion(const MontyInt(42)),
      );
      await provider.writing.future;
      var settled = false;
      Future<void> dispose() async {
        await runtime.dispose();
        settled = true;
      }

      final disposing = dispose();
      // Drain teardown work while the admitted write stays behind the barrier.
      await Future<void>.delayed(Duration.zero);
      final disposedDuringWrite = provider.disposals;
      final settledDuringWrite = settled;
      provider.releaseWrite();
      await collecting;
      await disposing;
      expect(disposedDuringWrite, 0);
      expect(settledDuringWrite, isFalse);
      expect(provider.disposals, 1);
      expect(
        await provider.access.call('Path.read_text', [
          const MontyString('/parent/result'),
        ], {}),
        const MontyString('done'),
      );
    });
  }

  test('D5-parent-dispose-close-fault', () async {
    final sessions = <RecordingSession>[];
    var poolCloses = 0;
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = RecordingSession(
          FakeMontySession()..willReturn(const MontyInt(42)),
        );
        sessions.add(session);

        return session;
      },
      closePool: () async => poolCloses++,
      extensions: [SandboxExtension()],
    );
    final handle = await spawnChild(runtime, '42');
    expect(await awaitChild(runtime, handle), const MontyInt(42));
    sessions.first.closeError = StateError('root close fault');
    var eventsClosed = false;
    final subscription = runtime.events.listen(
      // ignore: no-empty-block, this witness observes stream closure only.
      (_) {
        // Only stream closure is observed in this disposal witness.
      },
      onDone: () => eventsClosed = true,
    );
    addTearDown(subscription.cancel);
    final first = runtime.dispose();
    final joined = runtime.dispose();
    await Future.wait([
      expectLater(first, throwsStateError),
      expectLater(joined, throwsStateError),
    ]);
    expect(poolCloses, 1);
    expect(eventsClosed, isTrue);
    expect(sessions.map((session) => session.closeCalls), [1, 1]);
  });

  test('D5-terminal-log-fault', () async {
    final sandbox = SandboxExtension();
    final sessions = <RecordingSession>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = RecordingSession(
          FakeMontySession()..willReturn(const MontyInt(42)),
        );
        sessions.add(session);

        return session;
      },
      extensions: [sandbox],
    );
    addTearDown(runtime.dispose);
    await runtime.invoke('sandbox_await_all', {'handles': const MontyList([])});
    sandbox.logger = const _TerminalLogFault();
    final handle = await spawnChild(runtime, '42');
    expect(await awaitChild(runtime, handle), const MontyInt(42));
    await runtime.dispose();
    expect(sessions[1].closeCalls, 1);
  });

  test('D5-admit-k', () async {
    final arrived = Completer<MontySession>();
    var checkouts = 0;
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        if (checkouts++ == 0) return FakeMontySession();

        return arrived.future;
      },
      extensions: [SandboxExtension(maxChildren: 1)],
    );
    addTearDown(runtime.dispose);
    addTearDown(() {
      if (!arrived.isCompleted) {
        arrived.complete(FakeMontySession()..willReturn(const MontyInt(42)));
      }
    });
    final first = spawnChild(runtime, '42');
    // invoke attaches once; wait until the pending checkout holds admission.
    while (checkouts < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    await expectLater(spawnChild(runtime, '43'), throwsStateError);
    expect(checkouts, 2);
    arrived.complete(FakeMontySession()..willReturn(const MontyInt(42)));
    expect(await awaitChild(runtime, await first), const MontyInt(42));
  });

  for (final dispose in [false, true]) {
    test(dispose ? 'D5-late-checkout' : 'D5-context-late-checkout', () async {
      final arrived = Completer<MontySession>();
      final requested = Completer<void>();
      final lateSession = RecordingSession(FakeMontySession());
      var checkouts = 0;
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async {
          if (checkouts++ == 0) {
            return FakeMontySession()
              ..willCall('sandbox_spawn', args: [const MontyString('42')])
              ..willReturn(const MontyNone());
          }
          requested.complete();

          return arrived.future;
        },
        extensions: [SandboxExtension()],
      );
      addTearDown(runtime.dispose);
      final events = <BridgeEvent>[];
      final sub = runtime.events.listen(events.add);
      addTearDown(sub.cancel);
      final run = runtime.execute('spawn');
      final refused = expectLater(run.result, throwsStateError);
      await requested.future;
      final stopped = dispose ? runtime.dispose() : run.cancel();
      arrived.complete(lateSession);
      await stopped;
      await refused;
      // Disposal joins pending preparation even when cancellation won first.
      await runtime.dispose();
      expect(lateSession.closeCalls, 1);
      expect(lateSession.feeds, isEmpty);
      expect(events.whereType<BridgeChildEvent>(), isEmpty);
    });
  }

  for (final failure in [false, true]) {
    test('D5-retained-k failed=$failure', () async {
      final sessions = <RecordingSession>[];
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async {
          final fake = FakeMontySession();
          if (failure && sessions.isNotEmpty) {
            fake.willRaise('ValueError', message: 'child');
          } else {
            fake.willReturn(const MontyInt(42));
          }
          final session = RecordingSession(fake);
          sessions.add(session);

          return session;
        },
        extensions: [SandboxExtension(maxChildren: 1)],
      );
      addTearDown(runtime.dispose);
      final handle = await spawnChild(runtime, '42');
      if (failure) {
        await expectLater(
          awaitChild(runtime, handle),
          throwsA(isA<Exception>()),
        );
      } else {
        expect(await awaitChild(runtime, handle), const MontyInt(42));
      }
      expect(sessions[1].closeCalls, 1);
      await expectLater(spawnChild(runtime, '43'), throwsStateError);
      expect(sessions, hasLength(2));
      await freeChild(runtime, handle);
      await spawnChild(runtime, '44');
      expect(sessions, hasLength(3));
    });
  }

  for (final collectFirst in [false, true]) {
    test('D5-retained-lease collectFirst=$collectFirst', () async {
      final access = OSAccess(files: [MemoryFile('/parent/seed', 'seed')]);
      final writing = Completer<void>();
      final releaseWrite = Completer<void>();
      var writes = 0;
      final runtime = await MontyRuntime.start(
        pool: await childContractPool(),
        extensions: [SandboxExtension(maxChildren: 1)],
        os: (name, args, kwargs) {
          if (name == 'Path.write_bytes') {
            writes++;
            writing.complete();

            // Keep synchronous decline on every other OS path.
            // ignore: prefer-async-await
            return releaseWrite.future.then(
              (_) => access.call(name, args, kwargs),
            );
          }

          return access.call(name, args, kwargs);
        },
      );
      addTearDown(runtime.dispose);
      final handle = await spawnChild(
        runtime,
        "from pathlib import Path; Path('output').write_text('done'); 42",
      );
      await awaitChild(runtime, handle);
      Future<MontyValue> collect() => runtime.invoke('sandbox_await', {
        'handle': handle,
        'collect': const MontyDict([
          (MontyString('output'), MontyString('/parent/result')),
        ]),
      });
      if (collectFirst) {
        final collecting = collect();
        await writing.future;
        var freed = false;
        Future<void> free() async {
          await freeChild(runtime, handle);
          freed = true;
        }

        final freeing = free();
        await Future<void>.delayed(Duration.zero);
        expect(freed, isFalse);
        await expectLater(spawnChild(runtime, '7'), throwsStateError);
        releaseWrite.complete();
        expect(await collecting, const MontyInt(42));
        await freeing;
        expect(writes, 1);
      } else {
        await freeChild(runtime, handle);
        await expectLater(collect(), throwsArgumentError);
        expect(writes, 0);
      }
      expect(
        await awaitChild(runtime, await spawnChild(runtime, '7')),
        const MontyInt(7),
      );
    });
  }

  test('D5-live-collect', () async {
    final access = OSAccess(files: [MemoryFile('/parent/input', 'seed')]);
    final runtime = await MontyRuntime.start(
      pool: await childContractPool(),
      os: access.call,
      extensions: [SandboxExtension(maxChildren: 1)],
    );
    addTearDown(runtime.dispose);
    expect(
      await runtime.execute('''
from pathlib import Path
h = sandbox_spawn("from pathlib import Path; import os; Path('output').write_text(Path('input').read_text() + os.getcwd()); 42", files={'input': '/parent/input'})
sandbox_await(h, collect={'output': '/parent/first'})
sandbox_await(h, collect={'output': '/parent/second'})
[Path('/parent/first').read_text(), Path('/parent/second').read_text()]
''').result,
      const MontyList([MontyString('seed/work'), MontyString('seed/work')]),
    );
    await expectLater(
      runtime.invoke('sandbox_await', {
        'handle': const MontyInt(0),
        'collect': const MontyDict([
          (MontyString('missing'), MontyString('/parent/bad')),
        ]),
      }),
      throwsA(isA<ExternalException>()),
    );
    expect(
      await runtime.invoke('sandbox_await', {
        'handle': const MontyInt(0),
        'collect': const MontyDict([
          (MontyString('output'), MontyString('/parent/retry')),
        ]),
      }),
      const MontyInt(42),
    );
    await freeChild(runtime, const MontyInt(0));
    expect(
      await awaitChild(runtime, await spawnChild(runtime, '7')),
      const MontyInt(7),
    );
  });

  for (final streamError in [false, true]) {
    test(
      streamError ? 'D5-stream-error-no-done' : 'D5-dispose-throws',
      () async {
        final extension = _LifecycleExtension(
          streamError: streamError,
          throwDispose: true,
        );
        final sessions = <RecordingSession>[];
        final runtime = await startRuntimeWith(
          checkout: ({limits}) async {
            final session = RecordingSession(
              FakeMontySession()..willReturn(const MontyInt(42)),
            );
            if (sessions.isNotEmpty) {
              session.closeError = StateError('close fault');
            }
            sessions.add(session);

            return session;
          },
          extensions: [extension, SandboxExtension(maxChildren: 1)],
        );
        final handle = await spawnChild(runtime, '42');
        if (streamError) {
          await expectLater(
            awaitChild(runtime, handle),
            throwsA(isA<Exception>()),
          );
        } else {
          expect(await awaitChild(runtime, handle), const MontyInt(42));
        }
        expect(extension.clones.single.disposals, 1);
        expect(sessions[1].closeCalls, 1);
        await freeChild(runtime, handle);
        await spawnChild(runtime, '7');
        await runtime.dispose();
        expect(sessions[1].closeCalls, 1);
      },
    );
  }

  test('D5-attach-seed-failure', () async {
    final extension = _LifecycleExtension(throwAttach: true);
    final sessions = <RecordingSession>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = RecordingSession(
          FakeMontySession()..willReturn(const MontyInt(42)),
        );
        sessions.add(session);

        return session;
      },
      extensions: [extension, SandboxExtension(maxChildren: 1)],
    );
    addTearDown(runtime.dispose);
    await expectLater(
      runtime.invoke('sandbox_spawn', {
        'code': const MontyString('42'),
        'files': const MontyDict([
          (MontyString('in'), MontyString('/missing')),
        ]),
      }),
      throwsA(isA<ExternalException>()),
    );
    expect(sessions, hasLength(1));
    await expectLater(spawnChild(runtime, '42'), throwsStateError);
    expect(sessions[1].closeCalls, 1);
    expect(extension.clones.single.disposals, 1);
    extension.throwAttach = false;
    expect(
      await awaitChild(runtime, await spawnChild(runtime, '42')),
      const MontyInt(42),
    );
  });

  test('D5-free-race', () async {
    final held = Completer<void>();
    final sessions = <RecordingSession>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final fake = FakeMontySession()
          ..willHold(held.future)
          ..willReturn(const MontyInt(42));
        final session = RecordingSession(fake);
        sessions.add(session);

        return session;
      },
      extensions: [SandboxExtension()],
    );
    final handle = await spawnChild(runtime, '42');
    await Future.wait([
      freeChild(runtime, handle),
      freeChild(runtime, handle),
      runtime.dispose(),
    ]);
    expect(sessions[1].closeCalls, 1);
    held.complete();
  });

  test('D5-child-crash', () async {
    final sessions = <RecordingSession>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = RecordingSession(
          sessions.length == 1
              ? ThrowingSession(StateError('worker crash'))
              : (FakeMontySession()..willReturn(const MontyInt(42))),
        );
        sessions.add(session);

        return session;
      },
      extensions: [SandboxExtension(maxChildren: 1)],
    );
    addTearDown(runtime.dispose);
    final handle = await spawnChild(runtime, '42');
    await expectLater(
      awaitChild(runtime, handle),
      throwsA(predicate<Object>((e) => e.toString().contains('worker crash'))),
    );
    expect(sessions[1].closeCalls, 1);
    await freeChild(runtime, handle);
    expect(
      await awaitChild(runtime, await spawnChild(runtime, '42')),
      const MontyInt(42),
    );
  });

  for (final crash in [false, true]) {
    test(crash ? 'D5-parent-crash' : 'D5-cancel-origin', () async {
      final pool = await childContractPool();
      final sessions = <RecordingSession>[];
      final waiting = Completer<void>();
      final release = Completer<void>();
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async {
          final session = RecordingSession(await pool.checkout(limits: limits));
          sessions.add(session);

          return session;
        },
        extensions: [SandboxExtension()],
      );
      addTearDown(runtime.dispose);
      runtime.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'barrier'),
          handler: (_, _) async {
            waiting.complete();
            await release.future;

            return const MontyNone();
          },
        ),
      );
      // A successful earlier origin retains its child across a later failure.
      await runtime
          .execute('old = sandbox_spawn("import time; time.sleep(30)")')
          .result;
      final run = runtime.execute(
        'new = sandbox_spawn("import time; time.sleep(30)")\nbarrier()\nraise ValueError("parent")',
      );
      final refused = expectLater(
        run.result,
        throwsA(crash ? isA<MontyError>() : isA<StateError>()),
      );
      await waiting.future;
      if (crash) {
        release.complete();
      } else {
        await run.cancel();
        release.complete();
      }
      await refused;
      for (var i = 0; i < 20 && sessions[2].closeCalls == 0; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(sessions[2].closeCalls, 1);
      expect(sessions[1].closeCalls, 0);
      await freeChild(runtime, const MontyInt(0));
      await freeChild(runtime, const MontyInt(1));
      expect(
        await awaitChild(runtime, await spawnChild(runtime, '42')),
        const MontyInt(42),
      );
    });
  }

  test('D5-external-cancel-cleanup', () async {
    final pool = await childContractPool();
    final extension = _LifecycleExtension();
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: [extension, SandboxExtension()],
    );
    addTearDown(runtime.dispose);
    final handle = await spawnChild(runtime, 'resource_wait()');
    await extension.entered.future;
    expect(extension.waiters, hasLength(1));
    await freeChild(runtime, handle);
    expect(extension.waiters, isEmpty);
    expect(extension.clones.single.disposals, 1);
    expect(await runtime.execute('resource_id()').result, const MontyInt(-1));
  });

  test('D5-dispose-throws-coordinator', () async {
    final pool = await childContractPool();
    final first = ChildContractExtension('first');
    final throwing = ChildContractExtension('throwing', throwOnDispose: true);
    final last = ChildContractExtension('last');
    final parent = ExtensionCoordinator()
      ..register(first)
      ..register(throwing)
      ..register(last);
    await parent.attachTo(await childContractBridge(pool));
    final child = await parent.spawnChild(
      context: const ChildSpawnContext(childId: 1),
      bridge: await childContractBridge(pool),
    );
    await expectLater(child.disposeAll(), throwsStateError);
    for (final extension in [first, throwing, last]) {
      expect(extension.clones.single.disposals, 1);
      expect(extension.disposals, 0);
    }
    await expectLater(parent.disposeAll(), throwsStateError);
    for (final extension in [first, throwing, last]) {
      expect(extension.disposals, 1);
    }
  });
}

final class _LifecycleExtension extends MontyExtension {
  _LifecycleExtension({
    this.owner,
    this.streamError = false,
    this.throwDispose = false,
    this.throwAttach = false,
  });
  final _LifecycleExtension? owner;
  final bool streamError;
  final bool throwDispose;
  bool throwAttach;
  final clones = <_LifecycleExtension>[];
  final waiters = <Completer<MontyValue>>{};
  final entered = Completer<void>();
  int disposals = 0;
  @override
  String get namespace => 'resource';
  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;
  @override
  MontyExtension createChildInstance(ChildSpawnContext context) {
    final clone = _LifecycleExtension(
      owner: this,
      streamError: streamError,
      throwDispose: throwDispose,
      throwAttach: throwAttach,
    );
    clones.add(clone);

    return clone;
  }

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(name: 'resource_id'),
      handler: (_, _) async => const MontyInt(-1),
    ),
    HostFunction(
      schema: const HostFunctionSchema(name: 'resource_wait'),
      handler: (_, _) {
        final waiter = Completer<MontyValue>();
        waiters.add(waiter);
        owner!.waiters.add(waiter);
        owner!.entered.complete();

        return waiter.future;
      },
    ),
  ];
  @override
  Future<void> onAttach(AttachContext ctx) async {
    await super.onAttach(ctx);
    if (owner == null) return;
    if (throwAttach) throw StateError('attach fault');
    if (streamError) {
      (ctx as SessionBridge).addStreamWrapper((_, stream) {
        final controller = StreamController<BridgeEvent>();
        // ignore: no-empty-block, deliberately discard ordinary events.
        final sub = stream.listen((_) {
          /* Only the injected error is delivered to the child. */
        });
        controller.onListen = () =>
            controller.addError(StateError('stream fault'));
        controller.onCancel = sub.cancel;

        return controller.stream;
      });
    }
  }

  @override
  Future<void> onDispose() async {
    disposals++;
    for (final waiter in waiters.toList()) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('child disposed'), StackTrace.current);
      }
      owner?.waiters.remove(waiter);
    }
    waiters.clear();
    await super.onDispose();
    if (owner != null && throwDispose) throw StateError('dispose fault');
  }
}

final class _TerminalLogFault implements BridgeLogger {
  const _TerminalLogFault();

  @override
  BridgeLogger child(String name) => BridgeLogger.silent;
  @override
  void info(String message, {Map<String, Object?>? attributes}) =>
      throw StateError('log fault');
  @override
  // ignore: no-empty-block, only terminal logging throws in this fault probe.
  void debug(String message, {Map<String, Object?>? attributes}) {
    /* Creation logging succeeds. */
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Holds a captured parent OS write across coordinator teardown.
final class _CollectionProvider extends MontyExtension {
  final access = OSAccess(files: [MemoryFile('/parent/seed', 'seed')]);
  final writing = Completer<void>();
  int disposals = 0;
  final _writeReleased = Completer<void>();

  @override
  String get namespace => 'collection_provider';

  @override
  List<HostFunction> get functions => [];

  @override
  Map<String, OsHandler> get osContribution => {'Path.': _call};

  void releaseWrite() {
    if (!_writeReleased.isCompleted) _writeReleased.complete();
  }

  @override
  Future<void> onDispose() async {
    disposals++;
    await super.onDispose();
  }

  FutureOr<MontyValue> _call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    if (disposals != 0) throw StateError('provider disposed');
    if (name == 'Path.write_bytes') {
      writing.complete();

      return _write(args, kwargs);
    }

    return access.call(name, args, kwargs);
  }

  Future<MontyValue> _write(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) async {
    await _writeReleased.future;
    if (disposals != 0) throw StateError('provider disposed during collection');

    return access.call('Path.write_bytes', args, kwargs);
  }
}
