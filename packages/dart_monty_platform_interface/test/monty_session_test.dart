import 'dart:convert';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:dart_monty_platform_interface/src/monty_session.dart';
import 'package:test/test.dart';

/// Shared zero-cost usage for test results.
const _usage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

void main() {
  group('MontySession', () {
    late MockMontyPlatform mock;
    late MontySession session;

    setUp(() {
      mock = MockMontyPlatform();
      session = MontySession(platform: mock);
    });

    group('run()', () {
      test('set and read variable', () async {
        // First run: x = 42 — restore empty, persist {x: 42}
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 42}',
        );
        final r1 = await session.run('x = 42');
        expect(r1.value, isNull);

        // Verify restore got empty state
        expect(mock.resumeReturnValues.first, '{}');

        // Second run: x + 1 — restore {x: 42}, persist {x: 42}
        _enqueueRunCycle(
          mock,
          stateToRestore: '{"x": 42}',
          stateToPersist: '{"x": 42}',
          resultValue: 43,
        );
        final r2 = await session.run('x + 1');
        expect(r2.value, 43);

        // Verify restore got previous state
        expect(mock.resumeReturnValues[2], '{"x": 42}');
      });

      test('multiple types persist', () async {
        final state = jsonEncode({
          'a': 1,
          'b': 'hello',
          'c': [1, 2],
          'd': {'k': 'v'},
          'e': true,
          'f': null,
        });

        _enqueueRunCycle(mock, stateToRestore: '{}', stateToPersist: state);
        await session.run(
          'a = 1; b = "hello"; c = [1,2]; d = {"k": "v"}; e = True; f = None',
        );

        final persisted = session.state;
        expect(persisted['a'], 1);
        expect(persisted['b'], 'hello');
        expect(persisted['c'], [1, 2]);
        expect(persisted['d'], {'k': 'v'});
        expect(persisted['e'], true);
        expect(persisted['f'], isNull);
      });

      test('non-serializable silently dropped', () async {
        // Python postamble only persists JSON-safe values, so math module
        // won't appear in the persisted state.
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 42}',
        );
        await session.run('import math; x = 42');

        final persisted = session.state;
        expect(persisted, {'x': 42});
        expect(persisted.containsKey('math'), isFalse);
      });

      test('wraps code with preamble and postamble', () async {
        _enqueueRunCycle(mock, stateToRestore: '{}', stateToPersist: '{}');
        await session.run('x = 1');

        final startedCode = mock.lastStartCode!;
        expect(startedCode, contains('__restore_state__()'));
        expect(startedCode, contains('__persist_state__'));
        expect(startedCode, contains('x = 1'));
      });

      test('registers internal external functions', () async {
        _enqueueRunCycle(mock, stateToRestore: '{}', stateToPersist: '{}');
        await session.run('1 + 1');

        expect(
          mock.lastStartExternalFunctions,
          containsAll(['__restore_state__', '__persist_state__']),
        );
      });

      test('rejects unexpected external functions', () async {
        // restore → unexpected ext fn → resumeWithError → complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: ['url'],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                usage: _usage,
                error: MontyException(message: 'fetch not allowed'),
              ),
            ),
          );

        final result = await session.run('result = fetch("url")');
        expect(result.isError, isTrue);

        // Verify resumeWithError was called for the unexpected ext fn
        expect(mock.resumeErrorMessages, hasLength(1));
        expect(
          mock.resumeErrorMessages.first,
          contains('Unexpected external function'),
        );
      });

      test('handles MontyResolveFutures by resuming with null', () async {
        // restore → resolve futures → persist → complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1, 2]),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: ['{"x": 1}'],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: 1, usage: _usage),
            ),
          );

        final result = await session.run('x = 1');
        expect(result.value, 1);

        // resume(null) for: restore return, resolve_futures, persist return
        final nullResumes =
            mock.resumeReturnValues.where((v) => v == null).length;
        expect(nullResumes, greaterThanOrEqualTo(2));
      });
    });

    group('start()', () {
      test('intercepts restore and returns user pending', () async {
        // restore (internal) → user ext fn (fetch) returned to caller
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: ['https://example.com'],
            ),
          );

        final progress = await session.start(
          'result = fetch("https://example.com")',
          externalFunctions: ['fetch'],
        );

        expect(progress, isA<MontyPending>());
        final pending = progress as MontyPending;
        expect(pending.functionName, 'fetch');
        expect(pending.arguments, ['https://example.com']);

        // Verify restore was handled internally
        expect(mock.resumeReturnValues.first, '{}');
      });

      test('registers both internal and user external functions', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: [],
            ),
          );

        await session.start(
          'fetch()',
          externalFunctions: ['fetch'],
        );

        expect(
          mock.lastStartExternalFunctions,
          containsAll([
            '__restore_state__',
            '__persist_state__',
            'fetch',
          ]),
        );
      });

      test('wraps code with preamble and postamble', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: [],
            ),
          );

        await session.start(
          'result = fetch()',
          externalFunctions: ['fetch'],
        );

        final code = mock.lastStartCode!;
        expect(code, contains('__restore_state__()'));
        expect(code, contains('result = fetch()'));
        expect(code, contains('__persist_state__'));
      });
    });

    group('resume()', () {
      test('intercepts persist on completion', () async {
        // start: restore → user pending
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: ['url'],
            ),
          );

        final p1 = await session.start(
          'result = fetch("url")\nresult',
          externalFunctions: ['fetch'],
        );
        expect(p1, isA<MontyPending>());

        // resume: persist (internal) → complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: ['{"result": "data"}'],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: 'data', usage: _usage),
            ),
          );

        final p2 = await session.resume('data');
        expect(p2, isA<MontyComplete>());
        final complete = p2 as MontyComplete;
        expect(complete.result.value, 'data');

        // State was persisted
        expect(session.state, {'result': 'data'});
      });

      test('passes through user pending after resume', () async {
        // start: restore → first user pending
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'step1',
              arguments: [],
            ),
          );

        await session.start(
          'a = step1()\nb = step2()',
          externalFunctions: ['step1', 'step2'],
        );

        // resume step1 → second user pending (step2)
        mock.enqueueProgress(
          const MontyPending(
            functionName: 'step2',
            arguments: [],
          ),
        );

        final p2 = await session.resume('result1');
        expect(p2, isA<MontyPending>());
        expect((p2 as MontyPending).functionName, 'step2');
      });
    });

    group('resumeWithError()', () {
      test('intercepts persist after error resume completes', () async {
        // start: restore → user pending
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: 'fetch',
              arguments: ['url'],
            ),
          );

        await session.start(
          'try:\n  result = fetch("url")\nexcept: pass',
          externalFunctions: ['fetch'],
        );

        // resumeWithError: persist → complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: ['{}'],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(usage: _usage),
            ),
          );

        final p2 = await session.resumeWithError('network failure');
        expect(p2, isA<MontyComplete>());

        // Verify platform got the error message
        expect(mock.resumeErrorMessages.first, 'network failure');
      });
    });

    group('clearState()', () {
      test('resets persisted state', () async {
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 1}',
        );
        await session.run('x = 1');
        expect(session.state, {'x': 1});

        session.clearState();
        expect(session.state, isEmpty);
      });
    });

    group('state', () {
      test('empty on fresh session', () {
        expect(session.state, isEmpty);
      });

      test('returns copy (not mutable reference)', () async {
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 1}',
        );
        await session.run('x = 1');

        final s1 = session.state;
        s1['x'] = 999;
        expect(session.state['x'], 1);
      });
    });

    group('dispose()', () {
      test('clears state and marks disposed', () async {
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 1}',
        );
        await session.run('x = 1');

        session.dispose();
        expect(session.isDisposed, isTrue);
      });

      test('run() throws after dispose', () {
        session.dispose();
        expect(
          () => session.run('1'),
          throwsA(isA<StateError>()),
        );
      });

      test('clearState() throws after dispose', () {
        session.dispose();
        expect(
          () => session.clearState(),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('edge cases', () {
      test('error preserves previous state', () async {
        // First run succeeds with x=10
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"x": 10}',
        );
        await session.run('x = 10');
        expect(session.state, {'x': 10});

        // Second run errors — persist postamble never runs, so
        // MontyComplete has an error and no persist call happens.
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                usage: _usage,
                error: MontyException(
                  message: 'ZeroDivisionError',
                  excType: 'ZeroDivisionError',
                ),
              ),
            ),
          );

        final r2 = await session.run('1/0');
        expect(r2.isError, isTrue);

        // State preserved from first successful run
        expect(session.state, {'x': 10});
      });

      test('session isolation', () async {
        final mockA = MockMontyPlatform();
        final mockB = MockMontyPlatform();
        final sessionA = MontySession(platform: mockA);
        final sessionB = MontySession(platform: mockB);

        _enqueueRunCycle(
          mockA,
          stateToRestore: '{}',
          stateToPersist: '{"x": 1}',
        );
        await sessionA.run('x = 1');

        // Session B has empty state
        expect(sessionA.state, {'x': 1});
        expect(sessionB.state, isEmpty);

        sessionA.dispose();
        sessionB.dispose();
      });

      test('limits and scriptName forwarded to platform', () async {
        const limits = MontyLimits(
          memoryBytes: 1024,
          timeoutMs: 500,
          stackDepth: 10,
        );

        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{}',
        );
        await session.run('1', limits: limits, scriptName: 'test.py');

        expect(mock.lastStartLimits, limits);
        expect(mock.lastStartScriptName, 'test.py');
      });

      test('MontyResolveFutures during start/resume', () async {
        // start: restore → resolve_futures → user pending
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          );

        final progress = await session.start(
          'x = fetch()',
          externalFunctions: ['fetch'],
        );

        // MontyResolveFutures passes through to caller
        expect(progress, isA<MontyResolveFutures>());
      });

      test('large state round-trip', () async {
        // Build state with 100 variables
        final largeState = <String, Object?>{};
        for (var i = 0; i < 100; i++) {
          largeState['var_$i'] = i;
        }
        final stateJson = jsonEncode(largeState);

        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: stateJson,
        );
        await session.run('# set 100 variables');

        final persisted = session.state;
        expect(persisted.length, 100);
        for (var i = 0; i < 100; i++) {
          expect(persisted['var_$i'], i);
        }

        // Second run restores all 100
        _enqueueRunCycle(
          mock,
          stateToRestore: stateJson,
          stateToPersist: stateJson,
        );
        await session.run('# read them back');

        // Verify restore received the full state
        expect(
          mock.resumeReturnValues.last,
          isNot('{}'),
        );
      });

      test('dunder and underscore variables excluded', () async {
        // Python postamble filters out names starting with '_'
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{"public": 3}',
        );
        await session.run(
          '__private = 1; _also_private = 2; public = 3',
        );

        final persisted = session.state;
        expect(persisted, {'public': 3});
        expect(persisted.containsKey('__private'), isFalse);
        expect(persisted.containsKey('_also_private'), isFalse);
      });

      test('first run sends empty state to restore', () async {
        _enqueueRunCycle(
          mock,
          stateToRestore: '{}',
          stateToPersist: '{}',
        );
        await session.run('pass');

        // First resume call is the restore return value
        expect(mock.resumeReturnValues.first, '{}');
      });

      test('start() throws after dispose', () {
        session.dispose();
        expect(
          () => session.start('1', externalFunctions: ['f']),
          throwsA(isA<StateError>()),
        );
      });

      test('resume() throws after dispose', () {
        session.dispose();
        expect(
          () => session.resume('val'),
          throwsA(isA<StateError>()),
        );
      });

      test('resumeWithError() throws after dispose', () {
        session.dispose();
        expect(
          () => session.resumeWithError('err'),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}

/// Enqueues a full run cycle: restore → persist → complete.
///
/// The mock will return [MontyPending] for `__restore_state__`, then
/// [MontyPending] for `__persist_state__` with [stateToPersist], then
/// [MontyComplete] with [resultValue].
void _enqueueRunCycle(
  MockMontyPlatform mock, {
  required String stateToRestore,
  required String stateToPersist,
  Object? resultValue,
}) {
  mock
    // 1. restore
    ..enqueueProgress(
      const MontyPending(
        functionName: '__restore_state__',
        arguments: [],
      ),
    )
    // 2. persist
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [stateToPersist],
      ),
    )
    // 3. complete
    ..enqueueProgress(
      MontyComplete(
        result: MontyResult(value: resultValue, usage: _usage),
      ),
    );
}
