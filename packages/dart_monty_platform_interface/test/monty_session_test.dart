import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
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
          stateToPersist: {'x': 42},
        );
        final r1 = await session.run('x = 42');
        expect(r1.value, isNull);

        // Verify restore got empty state on first call
        expect(mock.resumeReturnValues.first, isEmpty);

        // Second run: x + 1 — restore {x: 42}, persist {x: 42}
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 42},
          resultValue: 43,
        );
        final r2 = await session.run('x + 1');
        expect(r2.value, 43);

        // Verify restore sent previous state
        final restoreArg = mock.resumeReturnValues[2];
        expect(restoreArg, isA<Map<String, Object?>>());
        expect((restoreArg! as Map<String, Object?>)['x'], 42);
      });

      test('multiple types persist', () async {
        final state = <String, Object?>{
          'a': 1,
          'b': 'hello',
          'c': [1, 2],
          'd': {'k': 'v'},
          'e': true,
          'f': null,
        };

        _enqueueRunCycle(mock, stateToPersist: state);
        await session.run(
          'a = 1\nb = "hello"\nc = [1,2]\n'
          'd = {"k": "v"}\ne = True\nf = None',
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
        // The persist postamble only captures vars that don't error.
        // The mock simulates that 'math' is not in the persisted dict.
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 42},
        );
        await session.run('x = 42');

        final persisted = session.state;
        expect(persisted, {'x': 42});
        expect(persisted.containsKey('math'), isFalse);
      });

      test('wraps code with restore and persist', () async {
        _enqueueRunCycle(mock, stateToPersist: {});
        await session.run('x = 1');

        final startedCode = mock.lastStartCode!;
        expect(startedCode, contains('__restore_state__()'));
        expect(startedCode, contains('__persist_state__'));
        expect(startedCode, contains('x = 1'));
      });

      test('generates per-variable persist code', () async {
        _enqueueRunCycle(mock, stateToPersist: {});
        await session.run('x = 1');

        final code = mock.lastStartCode!;
        // Should have try/except block for 'x'
        expect(code, contains('__d2["x"] = x'));
        expect(code, contains('except Exception:'));
      });

      test('registers internal external functions', () async {
        _enqueueRunCycle(mock, stateToPersist: {});
        await session.run('1 + 1');

        expect(
          mock.lastStartExternalFunctions,
          containsAll(['__restore_state__', '__persist_state__']),
        );
      });

      test('rejects unexpected external functions', () async {
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

        expect(mock.resumeErrorMessages, hasLength(1));
        expect(
          mock.resumeErrorMessages.first,
          contains('Unexpected external function'),
        );
      });

      test('handles MontyResolveFutures by resuming with null', () async {
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
              arguments: [
                <String, Object?>{'x': 1},
              ],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: 1, usage: _usage),
            ),
          );

        final result = await session.run('x = 1');
        expect(result.value, 1);

        final nullResumes =
            mock.resumeReturnValues.where((v) => v == null).length;
        expect(nullResumes, greaterThanOrEqualTo(2));
      });
    });

    group('start()', () {
      test('intercepts restore and returns user pending', () async {
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

      test('wraps code with restore and persist', () async {
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

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: [
                <String, Object?>{'result': 'data'},
              ],
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

        expect(session.state, {'result': 'data'});
      });

      test('passes through user pending after resume', () async {
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

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: [<String, Object?>{}],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(usage: _usage),
            ),
          );

        final p2 = await session.resumeWithError('network failure');
        expect(p2, isA<MontyComplete>());

        expect(mock.resumeErrorMessages.first, 'network failure');
      });
    });

    group('clearState()', () {
      test('resets persisted state', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 1},
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
          stateToPersist: {'x': 1},
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
          stateToPersist: {'x': 1},
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
          stateToPersist: {'x': 10},
        );
        await session.run('x = 10');
        expect(session.state, {'x': 10});

        // Second run errors — persist postamble never runs
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
          stateToPersist: {'x': 1},
        );
        await sessionA.run('x = 1');

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

        _enqueueRunCycle(mock, stateToPersist: {});
        await session.run('1', limits: limits, scriptName: 'test.py');

        expect(mock.lastStartLimits, limits);
        expect(mock.lastStartScriptName, 'test.py');
      });

      test('MontyResolveFutures during start/resume', () async {
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

        expect(progress, isA<MontyResolveFutures>());
      });

      test('large state round-trip', () async {
        final largeState = <String, Object?>{};
        for (var i = 0; i < 100; i++) {
          largeState['var_$i'] = i;
        }

        _enqueueRunCycle(mock, stateToPersist: largeState);
        await session.run('# set 100 variables');

        final persisted = session.state;
        expect(persisted.length, 100);
        for (var i = 0; i < 100; i++) {
          expect(persisted['var_$i'], i);
        }

        // Second run restores all 100
        _enqueueRunCycle(mock, stateToPersist: largeState);
        await session.run('# read them back');

        // Verify restore received the full state
        final restoreArg = mock.resumeReturnValues[2];
        expect(restoreArg, isA<Map<String, Object?>>());
        expect((restoreArg! as Map<String, Object?>).length, 100);
      });

      test('dunder and underscore variables excluded', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'public': 3},
        );
        await session.run(
          '__private = 1\n_also_private = 2\npublic = 3',
        );

        // extractAssignmentTargets should only find 'public'
        final code = mock.lastStartCode!;
        expect(code, contains('__d2["public"] = public'));
        expect(code, isNot(contains('__d2["__private"]')));
        expect(code, isNot(contains('__d2["_also_private"]')));
      });

      test('first run sends empty state to restore', () async {
        _enqueueRunCycle(mock, stateToPersist: {});
        await session.run('pass');

        // First resume call is the restore return value (empty map)
        expect(mock.resumeReturnValues.first, isEmpty);
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

    group('result capture (_captureLastExpression)', () {
      test('captures bare expression as last line', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 42}, resultValue: 43);
        await session.run('x = 42');

        // Run with expression as last line
        _enqueueRunCycle(mock, stateToPersist: {'x': 42}, resultValue: 43);
        await session.run('x + 1');

        final code = mock.lastStartCode!;
        // Should have __r = (x + 1) and trailing __r
        expect(code, contains('__r = (x + 1)'));
        expect(code.trimRight().endsWith('__r'), isTrue);
      });

      test('does not capture assignment as last line', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');

        final code = mock.lastStartCode!;
        expect(code, isNot(contains('__r = ')));
        expect(code.trimRight().endsWith('__r'), isFalse);
      });

      test('does not capture statement keywords', () async {
        for (final stmt in [
          'if True:\n    pass',
          'for i in [1]:\n    pass',
          'import os',
          'def foo():\n    pass',
          'class Foo:\n    pass',
        ]) {
          final m = MockMontyPlatform();
          final s = MontySession(platform: m);

          _enqueueRunCycle(m, stateToPersist: {});
          await s.run(stmt);

          final code = m.lastStartCode!;
          expect(
            code.trimRight().endsWith('__r'),
            isFalse,
            reason: 'Should not capture: $stmt',
          );

          s.dispose();
        }
      });

      test('captures function call as expression', () async {
        _enqueueRunCycle(mock, stateToPersist: {}, resultValue: 'hi');
        await session.run('str(42)');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (str(42))'));
      });

      test('captures variable reference as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 1},
          resultValue: 1,
        );
        await session.run('x');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (x)'));
      });

      test('captures list literal as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: [1, 2, 3],
        );
        await session.run('[1, 2, 3]');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = ([1, 2, 3])'));
      });

      test('skips trailing comments and blank lines', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: 42,
        );
        await session.run('42\n# comment\n');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (42)'));
      });
    });

    group('extractAssignmentTargets', () {
      test('finds simple assignments', () {
        expect(
          MontySession.extractAssignmentTargets('x = 42'),
          {'x'},
        );
      });

      test('finds multiple assignments', () {
        expect(
          MontySession.extractAssignmentTargets('x = 1\ny = 2\nz = 3'),
          {'x', 'y', 'z'},
        );
      });

      test('excludes underscore-prefixed names', () {
        expect(
          MontySession.extractAssignmentTargets(
            '__private = 1\n_hidden = 2\npublic = 3',
          ),
          {'public'},
        );
      });

      test('excludes comparisons (==)', () {
        expect(
          MontySession.extractAssignmentTargets('x == 42'),
          isEmpty,
        );
      });

      test('handles no assignments', () {
        expect(
          MontySession.extractAssignmentTargets('print("hello")'),
          isEmpty,
        );
      });

      test('handles indented code (skips block-level)', () {
        const code = 'if True:\n    y = 2\nx = 1';
        final targets = MontySession.extractAssignmentTargets(code);
        expect(targets, contains('x'));
        // Indented 'y = 2' should NOT be captured
        expect(targets, isNot(contains('y')));
      });

      test('handles semicolons (multi-statement lines)', () {
        expect(
          MontySession.extractAssignmentTargets(
            'x = 1; y = 2; z = 3',
          ),
          {'x', 'y', 'z'},
        );
      });
    });
  });
}

/// Enqueues a full run cycle: restore → persist → complete.
void _enqueueRunCycle(
  MockMontyPlatform mock, {
  required Map<String, Object?> stateToPersist,
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
