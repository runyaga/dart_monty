@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';
import '_child_contract.dart';

// Browser timer granularity can report a timeout slightly early.
const _timerJitter = Duration(milliseconds: 20);

void main() {
  for (final transfer in [false, true]) {
    test(
      transfer
          ? 'a finite transfer checkout times out'
          : 'a finite child checkout times out',
      () async {
        const budget = Duration(milliseconds: 100);
        const limits = ResourceLimits(maxFeedDuration: Duration(seconds: 2));
        final pool = await Monty.start(
          workerLocation: acceptanceWorkerLocation,
          maxProcesses: 1,
          checkoutTimeout: budget,
        );
        addTearDown(pool.close);
        var transfers = 0;
        final runtime = await MontyRuntime.start(
          pool: pool,
          limits: limits,
          extensions: [SandboxExtension()],
          os: (_, _, _) async {
            transfers++;
            // A caller adapter acquires its own finite session; the held root
            // cannot recursively serve the requested transfer.
            final session = await pool.checkout(limits: limits);
            try {
              return await session.feedRun('42');
            } finally {
              await session.close();
            }
          },
        );
        addTearDown(runtime.dispose);
        final watch = Stopwatch()..start();
        await expectLater(
          runtime.invoke('sandbox_spawn', {
            'code': const MontyString('42'),
            if (transfer)
              'files': const MontyDict([
                (MontyString('input'), MontyString('/parent/input')),
              ]),
          }),
          throwsA(isA<TimeoutException>()),
        );
        expect(watch.elapsed, greaterThanOrEqualTo(budget - _timerJitter));
        expect(watch.elapsed, lessThan(budget + const Duration(seconds: 3)));
        expect(transfers, transfer ? 1 : 0);
        await runtime.dispose();
        final fresh = await pool.checkout(limits: limits);
        expect(await fresh.feedRun('42'), const MontyInt(42));
        await fresh.close();
      },
    );
  }

  test('a late child checkout closes after timeout', () async {
    final session = _LateSession();
    final arrived = Completer<MontySession>();
    final requested = Completer<void>();
    var checkouts = 0;
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        if (checkouts++ == 0) return FakeMontySession();
        requested.complete();

        return arrived.future;
      },
      extensions: [SandboxExtension()],
    );
    final spawning = spawnChild(runtime, '42');
    final refused = expectLater(spawning, throwsStateError);
    await requested.future;
    final disposal = runtime.dispose();
    arrived.complete(session);
    await disposal;
    await refused;
    expect(session.closes, 1);
    expect(session.unexpectedCalls, 0);
  });

  test('a finite sub-execution checkout times out', () async {
    const budget = Duration(milliseconds: 100);
    final pool = await Monty.start(
      workerLocation: acceptanceWorkerLocation,
      maxProcesses: 1,
      checkoutTimeout: budget,
    );
    addTearDown(pool.close);
    final runtime = await MontyRuntime.start(
      pool: pool,
      limits: const ResourceLimits(maxFeedDuration: Duration(seconds: 2)),
    );
    addTearDown(runtime.dispose);
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'nested'),
        handler: (_, ctx) => ctx.subExecute!('42'),
      ),
    );
    final watch = Stopwatch()..start();
    await expectLater(
      runtime.invoke('nested', {}),
      throwsA(isA<TimeoutException>()),
    );
    watch.stop();
    expect(watch.elapsed, greaterThanOrEqualTo(budget - _timerJitter));
    expect(watch.elapsed, lessThan(budget + const Duration(seconds: 3)));
    expect(await runtime.execute('40 + 2').result, const MontyInt(42));
    await runtime.dispose();
    // Disposal must release the held slot without closing this caller pool.
    final fresh = await pool.checkout(
      limits: const ResourceLimits(maxFeedDuration: Duration(seconds: 2)),
    );
    addTearDown(fresh.close);
    expect(await fresh.feedRun('6 * 7'), const MontyInt(42));
  });

  // Both child checkout and sub-execution must close a late session once.
  test('a late sub-execution checkout closes after timeout', () async {
    final lateSession = _LateSession();
    final arrived = Completer<MontySession>();
    final requested = Completer<void>();
    final token = Completer<CancelToken>();
    final settled = Completer<void>();
    var checkouts = 0;
    const limits = ResourceLimits(maxFeedDuration: Duration(seconds: 2));
    final runtime = await startRuntimeWith(
      limits: limits,
      checkout: ({limits}) async {
        checkouts++;
        if (checkouts == 1) {
          return FakeMontySession()
            ..willCall('nested')
            ..willReturn(const MontyInt(42));
        }
        expect(limits?.maxFeedDuration, const Duration(seconds: 2));
        requested.complete();

        return arrived.future;
      },
    );
    addTearDown(runtime.dispose);
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'nested'),
        handler: (_, ctx) {
          token.complete(ctx.cancelToken);

          return ctx.subExecute!('42').whenComplete(settled.complete);
        },
      ),
    );
    final run = runtime.execute('nested()');
    final refused = expectLater(run.result, throwsStateError);
    await requested.future;
    final cancelled = run.cancel();
    await (await token.future).future;
    arrived.complete(lateSession);
    await cancelled;
    await refused;
    await settled.future;
    expect(checkouts, 2);
    expect(lateSession.closes, 1);
    expect(lateSession.unexpectedCalls, 0);
    await runtime.dispose();
    expect(lateSession.closes, 1);
  });
}

// A late session must only be closed; any other interface call is a failure.
final class _LateSession implements MontySession {
  int closes = 0;
  int unexpectedCalls = 0;

  @override
  Future<void> close() async => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    unexpectedCalls++;

    return super.noSuchMethod(invocation);
  }
}
