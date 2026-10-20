@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';
import '../src/_recording_session.dart';

void main() {
  for (final script in [false, true]) {
    for (final mixed in [false, true]) {
      test(
        'sub-executions receive all seven limits script=$script mixed=$mixed',
        () async {
          final limits = ResourceLimits(
            maxFeedDuration: const Duration(seconds: 11),
            maxTurnDuration: mixed ? null : const Duration(seconds: 3),
            maxMemory: 16000000,
            gcInterval: mixed ? null : 123,
            maxRecursionDepth: 71,
            maxSuspensions: mixed ? null : 13,
            maxTotalSleep: const Duration(milliseconds: 17),
          );
          final observed = <ResourceLimits?>[];
          final sessions = <RecordingSession>[];
          final runtime = await startRuntimeWith(
            limits: limits,
            checkout: ({limits}) async {
              observed.add(limits);
              final fake = FakeMontySession();
              if (sessions.isEmpty) {
                fake.willCall(
                  script ? 'run_script' : 'probe',
                  args: script ? [const MontyString('child.py')] : [],
                );
              }
              fake.willReturn(const MontyInt(42));
              final session = RecordingSession(fake);
              sessions.add(session);

              return session;
            },
          );
          addTearDown(runtime.dispose);
          runtime.register(
            script
                ? buildRunScriptFunction((_) => '42')
                : HostFunction(
                    schema: const HostFunctionSchema(name: 'probe'),
                    handler: (_, ctx) => ctx.subExecute!('42'),
                  ),
          );
          await runtime.execute('probe()').result;
          expect(observed, hasLength(2));
          final [_, childLimits] = observed;
          final [_, childSession] = sessions;
          expect(
            childLimits?.maxFeedDuration,
            limits.maxFeedDuration,
            reason: 'maxFeedDuration',
          );
          expect(
            childLimits?.maxTurnDuration,
            limits.maxTurnDuration,
            reason: 'maxTurnDuration',
          );
          expect(childLimits?.maxMemory, limits.maxMemory, reason: 'maxMemory');
          expect(
            childLimits?.gcInterval,
            limits.gcInterval,
            reason: 'gcInterval',
          );
          expect(
            childLimits?.maxRecursionDepth,
            limits.maxRecursionDepth,
            reason: 'maxRecursionDepth',
          );
          expect(
            childLimits?.maxSuspensions,
            limits.maxSuspensions,
            reason: 'maxSuspensions',
          );
          expect(
            childLimits?.maxTotalSleep,
            limits.maxTotalSleep,
            reason: 'maxTotalSleep',
          );

          expect(identical(childLimits, limits), isTrue);
          expect(childSession.closed, isTrue);
        },
      );
    }
  }
  for (final script in [false, true]) {
    for (final sleep in [false, true]) {
      test(
        'sub-executions enforce the ${sleep ? 'sleep' : 'suspension'} '
        'limit script=$script',
        () async {
          final pool = await Monty.start(
            workerLocation: acceptanceWorkerLocation,
            maxProcesses: 2,
            checkoutTimeout: const Duration(seconds: 5),
          );
          addTearDown(pool.close);
          final sessions = <RecordingSession>[];
          final limits = sleep
              ? const ResourceLimits(maxTotalSleep: Duration.zero)
              : const ResourceLimits(maxSuspensions: 2);
          final runtime = await startRuntimeWith(
            limits: limits,
            checkout: ({limits}) async {
              final session = RecordingSession(
                await pool.checkout(limits: limits),
              );
              sessions.add(session);

              return session;
            },
          );
          addTearDown(runtime.dispose);
          var code = sleep
              ? 'import time\ntime.sleep(0.001)\n42'
              : 'import time\ntime.sleep(0)\ntime.sleep(0)\ntime.sleep(0)\n42';
          runtime.register(
            script
                ? buildRunScriptFunction((_) => code)
                : HostFunction(
                    schema: const HostFunctionSchema(name: 'probe'),
                    handler: (_, ctx) => ctx.subExecute!(code),
                  ),
          );
          final call = script ? "run_script('child.py')" : 'probe()';
          final isMontyError = isA<MontyError>();
          final failingRun = runtime.execute(call);
          await expectLater(
            failingRun.result,
            throwsA(
              isMontyError.having(
                (e) => e.exception.excType,
                'outer type',
                'RuntimeError',
              ),
            ),
          );
          expect(sessions, hasLength(2));
          final [_, nestedSession] = sessions;
          expect(
            nestedSession.feedError,
            isMontyError
                .having(
                  (e) => e.exception.excType,
                  'nested type',
                  sleep ? 'TimeoutError' : 'RuntimeError',
                )
                .having(
                  (e) => e.exception.message,
                  'nested reason',
                  contains(sleep ? 'sleep limit exceeded' : 'suspension limit'),
                ),
          );
          expect(nestedSession.closed, isTrue);
          expect(await runtime.execute('42').result, const MontyInt(42));
          code = '42';
          expect(await runtime.execute(call).result, const MontyInt(42));
          final [..., recoveredSession] = sessions;
          expect(recoveredSession.closed, isTrue);
          expect(recoveredSession.feedError, isNull);
        },
      );
    }
  }
}
