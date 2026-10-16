// Keep guest programs and historical case IDs intact.
// ignore_for_file: lines_longer_than_80_chars
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../src/_recording_session.dart';
import '_child_contract.dart';

// Accepted limits cannot be observed through the runtime checkout seam yet.
// Keep rejection witnesses here; accepted selection/reduction remains D5-A.
Future<MontyRuntime> _runtime(
  ResourceLimits? owner,
  ResourceLimits? child,
) async {
  final runtime = await startRuntimeWith(
    checkout: ({limits}) async => FakeMontySession(),
    limits: owner,
    extensions: [SandboxExtension(childLimits: child)],
  );
  addTearDown(runtime.dispose);

  return runtime;
}

Future<MontyValue> _spawn(MontyRuntime runtime, String field, int value) =>
    runtime.invoke('sandbox_spawn', {
      'code': const MontyString('42'),
      field: MontyInt(value),
    });

void main() {
  test('a child receives all seven limits', () async {
    const selected = ResourceLimits(
      maxFeedDuration: Duration(seconds: 11),
      maxTurnDuration: Duration(seconds: 3),
      maxMemory: 16000000,
      gcInterval: 123,
      maxRecursionDepth: 71,
      maxSuspensions: 13,
      maxTotalSleep: Duration(milliseconds: 17),
    );
    final observed = <ResourceLimits?>[];
    final runtime = await startRuntimeWith(
      limits: selected,
      extensions: [SandboxExtension()],
      checkout: ({limits}) async {
        observed.add(limits);

        return FakeMontySession()..willReturn(const MontyInt(42));
      },
    );
    addTearDown(runtime.dispose);
    final handle = await runtime.invoke('sandbox_spawn', {
      'code': const MontyString('42'),
      'memory_bytes': const MontyInt(1000000),
    });
    expect(await awaitChild(runtime, handle), const MontyInt(42));
    expect(observed, hasLength(2));
    expect(
      observed[1],
      const ResourceLimits(
        maxFeedDuration: Duration(seconds: 11),
        maxTurnDuration: Duration(seconds: 3),
        maxMemory: 1000000,
        gcInterval: 123,
        maxRecursionDepth: 71,
        maxSuspensions: 13,
        maxTotalSleep: Duration(milliseconds: 17),
      ),
    );
  });

  test('a child can reduce its inherited limits', () async {
    final observed = <ResourceLimits?>[];
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        observed.add(limits);

        return FakeMontySession()..willReturn(const MontyInt(42));
      },
      extensions: [SandboxExtension()],
    );
    addTearDown(runtime.dispose);
    for (final field in ['timeout_ms', 'memory_bytes']) {
      await expectLater(_spawn(runtime, field, -1), throwsArgumentError);
    }
    expect(observed, hasLength(1));
    final handle = await runtime.invoke('sandbox_spawn', {
      'code': const MontyString('42'),
      'timeout_ms': const MontyInt(10),
      'memory_bytes': const MontyInt(12345),
    });
    expect(await awaitChild(runtime, handle), const MontyInt(42));
    expect(
      observed[1],
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 10),
        maxMemory: 12345,
      ),
    );
  });
  for (final sleep in [false, true]) {
    test(
      sleep
          ? 'a child enforces its total sleep limit'
          : 'a child enforces its suspension limit',
      () async {
        final pool = await childContractPool();
        final sessions = <RecordingSession>[];
        final runtime = await startRuntimeWith(
          checkout: ({limits}) async {
            final session = RecordingSession(
              await pool.checkout(limits: limits),
            );
            sessions.add(session);

            return session;
          },
          extensions: [
            SandboxExtension(
              childLimits: sleep
                  ? const ResourceLimits(maxTotalSleep: Duration.zero)
                  : const ResourceLimits(maxSuspensions: 2),
            ),
          ],
        );
        addTearDown(runtime.dispose);
        final handle = await spawnChild(
          runtime,
          sleep
              ? 'import time; time.sleep(0.001); 42'
              : 'import time; time.sleep(0); time.sleep(0); time.sleep(0); 42',
        );
        await expectLater(
          awaitChild(runtime, handle),
          throwsA(isA<Exception>()),
        );
        expect(
          sessions[1].feedError,
          isA<MontyError>().having(
            (e) => e.exception.message,
            'limit error',
            contains(sleep ? 'sleep limit exceeded' : 'suspension limit'),
          ),
        );
        expect(sessions[1].closeCalls, 1);
        expect(
          await awaitChild(runtime, await spawnChild(runtime, '42')),
          const MontyInt(42),
        );
      },
    );
  }

  for (final mixed in [false, true]) {
    for (final explicit in [false, true]) {
      test(
        '${explicit ? "explicit limits stay independent" : "omitted limits preserve the whole owner limit"} mixed=$mixed',
        () async {
          final selected = ResourceLimits(
            maxFeedDuration: const Duration(seconds: 11),
            maxTurnDuration: mixed ? null : const Duration(seconds: 3),
            maxMemory: 16000000,
            gcInterval: mixed ? null : 123,
            maxRecursionDepth: 71,
            maxSuspensions: mixed ? null : 13,
            maxTotalSleep: const Duration(milliseconds: 17),
          );
          final observed = <ResourceLimits?>[];
          final runtime = await startRuntimeWith(
            limits: explicit
                ? const ResourceLimits(maxMemory: 1, gcInterval: 2)
                : selected,
            extensions: [
              SandboxExtension(childLimits: explicit ? selected : null),
            ],
            checkout: ({limits}) async {
              observed.add(limits);

              return FakeMontySession()..willReturn(const MontyInt(42));
            },
          );
          addTearDown(runtime.dispose);
          final handle = await runtime.invoke('sandbox_spawn', {
            'code': const MontyString('42'),
          });
          expect(
            await runtime.invoke('sandbox_await', {'handle': handle}),
            const MontyInt(42),
          );
          expect(observed, hasLength(2));
          expect(observed[1], same(selected));
          final reduced = await runtime.invoke('sandbox_spawn', {
            'code': const MontyString('42'),
            'timeout_ms': const MontyInt(1000),
            'memory_bytes': const MontyInt(1000000),
          });
          await runtime.invoke('sandbox_await', {'handle': reduced});
          expect(
            observed[2],
            ResourceLimits(
              maxFeedDuration: const Duration(seconds: 1),
              maxMemory: 1000000,
              maxTurnDuration: selected.maxTurnDuration,
              gcInterval: selected.gcInterval,
              maxRecursionDepth: selected.maxRecursionDepth,
              maxSuspensions: selected.maxSuspensions,
              maxTotalSleep: selected.maxTotalSleep,
            ),
          );
        },
      );
    }
  }

  test('omitted limits reject invalid owner limits before checkout', () async {
    for (final owner in [
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 100),
        maxMemory: 200,
      ),
      const ResourceLimits(maxMemory: 200),
    ]) {
      final runtime = await _runtime(owner, null);
      await expectLater(
        _spawn(runtime, 'memory_bytes', 201),
        throwsArgumentError,
      );
      if (owner.maxFeedDuration != null) {
        await expectLater(
          _spawn(runtime, 'timeout_ms', 101),
          throwsArgumentError,
        );
      }
    }
  });

  test('explicit limits reject invalid values before checkout', () async {
    const owner = ResourceLimits(
      maxFeedDuration: Duration(milliseconds: 10),
      maxMemory: 20,
    );
    final stricter = await _runtime(
      owner,
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 1),
        maxMemory: 2,
      ),
    );
    await expectLater(_spawn(stricter, 'timeout_ms', 10), throwsArgumentError);
    await expectLater(
      _spawn(stricter, 'memory_bytes', 20),
      throwsArgumentError,
    );
  });

  test('child limits reject guest escalation before checkout', () async {
    final finite = await _runtime(
      null,
      const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 100),
        maxMemory: 100,
      ),
    );
    final unlimited = await _runtime(null, null);
    for (final field in ['timeout_ms', 'memory_bytes']) {
      for (final runtime in [finite, unlimited]) {
        await expectLater(_spawn(runtime, field, -1), throwsArgumentError);
      }
      await expectLater(_spawn(finite, field, 101), throwsArgumentError);
    }
  });
}
