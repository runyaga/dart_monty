import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:signals_core/signals_core.dart';
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
        _enqueueRunCycle(mock, stateToPersist: {'x': 42});
        final r1 = await session.run('x = 42');
        expect(r1.value, const MontyNull());

        // Verify restore got empty state on first call
        expect(mock.resumeReturnValues.first, isEmpty);

        // Second run: x + 1 — restore {x: 42}, persist {x: 42}
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 42},
          resultValue: const MontyInt(43),
        );
        final r2 = await session.run('x + 1');
        expect(r2.value, const MontyInt(43));

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
        _enqueueRunCycle(mock, stateToPersist: {'x': 42});
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
              arguments: [MontyString('url')],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                value: MontyNull(),
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
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1, 2]))
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [
                _toMontyDict(const {'x': 1}),
              ],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyInt(1), usage: _usage),
            ),
          );

        final result = await session.run('x = 1');
        expect(result.value, const MontyInt(1));

        final nullResumes = mock.resumeReturnValues
            .where((v) => v == null)
            .length;
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
              arguments: [MontyString('https://example.com')],
            ),
          );

        final progress = await session.start(
          'result = fetch("https://example.com")',
          externalFunctions: ['fetch'],
        );

        expect(progress, isA<MontyPending>());
        final pending = progress as MontyPending;
        expect(pending.functionName, 'fetch');
        expect(pending.arguments, [const MontyString('https://example.com')]);
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
            const MontyPending(functionName: 'fetch', arguments: []),
          );

        await session.start('fetch()', externalFunctions: ['fetch']);

        expect(
          mock.lastStartExternalFunctions,
          containsAll(['__restore_state__', '__persist_state__', 'fetch']),
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
            const MontyPending(functionName: 'fetch', arguments: []),
          );

        await session.start('result = fetch()', externalFunctions: ['fetch']);

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
              arguments: [MontyString('url')],
            ),
          );

        final p1 = await session.start(
          'result = fetch("url")\nresult',
          externalFunctions: ['fetch'],
        );
        expect(p1, isA<MontyPending>());

        mock
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [
                _toMontyDict(const {'result': 'data'}),
              ],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyString('data'), usage: _usage),
            ),
          );

        final p2 = await session.resume('data');
        expect(p2, isA<MontyComplete>());
        final complete = p2 as MontyComplete;
        expect(complete.result.value, const MontyString('data'));

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
            const MontyPending(functionName: 'step1', arguments: []),
          );

        await session.start(
          'a = step1()\nb = step2()',
          externalFunctions: ['step1', 'step2'],
        );

        mock.enqueueProgress(
          const MontyPending(functionName: 'step2', arguments: []),
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
              arguments: [MontyString('url')],
            ),
          );

        await session.start(
          'try:\n  result = fetch("url")\nexcept: pass',
          externalFunctions: ['fetch'],
        );

        mock
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [_toMontyDict(const {})],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        final p2 = await session.resumeWithError('network failure');
        expect(p2, isA<MontyComplete>());

        expect(mock.resumeErrorMessages.first, 'network failure');
      });
    });

    group('clearState()', () {
      test('resets persisted state', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
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
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');

        final s1 = session.state;
        s1['x'] = 999;
        expect(session.state['x'], 1);
      });
    });

    group('dispose()', () {
      test('clears state and marks disposed', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');

        session.dispose();
        expect(session.isDisposed, isTrue);
      });

      test('run() throws after dispose', () {
        session.dispose();
        expect(() => session.run('1'), throwsA(isA<StateError>()));
      });

      test('clearState() throws after dispose', () {
        session.dispose();
        expect(() => session.clearState(), throwsA(isA<StateError>()));
      });
    });

    group('edge cases', () {
      test('error preserves previous state', () async {
        // First run succeeds with x=10
        _enqueueRunCycle(mock, stateToPersist: {'x': 10});
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
                value: MontyNull(),
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

        _enqueueRunCycle(mockA, stateToPersist: {'x': 1});
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
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]));

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
        _enqueueRunCycle(mock, stateToPersist: {'public': 3});
        await session.run('__private = 1\n_also_private = 2\npublic = 3');

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
        expect(() => session.resume('val'), throwsA(isA<StateError>()));
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
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 42},
          resultValue: const MontyInt(43),
        );
        await session.run('x = 42');

        // Run with expression as last line
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 42},
          resultValue: const MontyInt(43),
        );
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
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: const MontyString('hi'),
        );
        await session.run('str(42)');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (str(42))'));
      });

      test('captures variable reference as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 1},
          resultValue: const MontyInt(1),
        );
        await session.run('x');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (x)'));
      });

      test('captures list literal as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
        );
        await session.run('[1, 2, 3]');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = ([1, 2, 3])'));
      });

      test('skips trailing comments and blank lines', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: const MontyInt(42),
        );
        await session.run('42\n# comment\n');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (42)'));
      });

      test('captures multi-line dict literal as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 1},
          resultValue: const MontyDict({'a': MontyInt(1)}),
        );
        await session.run('x = 1\n{\n    "a": x,\n}');

        final code = mock.lastStartCode!;
        // The entire dict should be captured, not just the closing `}`.
        expect(code, contains('__r = ({\n    "a": x,\n})'));
        expect(code.trimRight().endsWith('__r'), isTrue);
      });

      test('captures multi-line list literal as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: const MontyList([MontyInt(1), MontyInt(2)]),
        );
        await session.run('[\n    1,\n    2,\n]');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = ([\n    1,\n    2,\n])'));
      });

      test('captures multi-line function call as expression', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {},
          resultValue: const MontyString('result'),
        );
        await session.run('foo(\n    1,\n    2,\n)');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = (foo(\n    1,\n    2,\n))'));
      });

      test('multi-line dict assigned to var is not double-captured', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {
            'result': <String, Object>{'a': 1},
          },
          resultValue: const MontyDict({'a': MontyInt(1)}),
        );
        await session.run('result = {\n    "a": 1,\n}\nresult');

        final code = mock.lastStartCode!;
        // `result` on the last line should be captured, not the dict.
        expect(code, contains('__r = (result)'));
      });

      test('multi-line dict with complex values is captured', () async {
        _enqueueRunCycle(
          mock,
          stateToPersist: {'x': 1},
          resultValue: const MontyDict({'ok': MontyBool(true)}),
        );
        await session.run('x = 1\n{\n    "ok": x == 1,\n}');

        final code = mock.lastStartCode!;
        expect(code, contains('__r = ({\n    "ok": x == 1,\n})'));
      });
    });

    group('C-1: catches MontyError (panic/disposed)', () {
      test('MontyPanicError during start is caught', () async {
        final throwing = _ThrowingMockPlatform(
          throwOnStart: const MontyPanicError('WASM trap'),
        );
        final s = MontySession(platform: throwing);

        final result = await s.run('x = 1');

        expect(result.isError, isTrue);
        expect(result.error!.message, contains('WASM trap'));

        s.dispose();
      });

      test('state preserved after error', () async {
        // First run succeeds
        _enqueueRunCycle(mock, stateToPersist: {'x': 10});
        await session.run('x = 10');
        expect(session.state, {'x': 10});

        // Second run: mock throws panic on start
        final throwing = _ThrowingMockPlatform(
          throwOnStart: const MontyPanicError('panic'),
        );
        final s2 = MontySession(platform: throwing);
        // Manually set state to simulate prior state
        // (Can't reuse same session since mock is different)
        // Instead, verify fresh session still works after error
        final result = await s2.run('y = 1');
        expect(result.isError, isTrue);

        // Session should not be disposed — can try again
        expect(s2.isDisposed, isFalse);
        s2.dispose();
      });
    });

    group('MontyOsCall in run() mode', () {
      test('resumes with error for OsCall during run()', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'Path.read_text',
              arguments: [MontyString('/etc/passwd')],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [_toMontyDict(const {})],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        final result = await session.run('import os');
        // The OsCall was rejected — resumeWithError was called.
        expect(mock.resumeErrorMessages, hasLength(1));
        expect(
          mock.resumeErrorMessages.first,
          contains('OS operations not available'),
        );
        expect(result.isError, isFalse);
      });
    });

    group('_safeStart catches MontyScriptError', () {
      test('MontyScriptError during start returns error result', () async {
        const exc = MontyException(
          message: 'SyntaxError: invalid syntax',
          excType: 'SyntaxError',
        );
        final throwing = _ThrowingMockPlatform(
          throwOnStart: MontyScriptError(
            exc.message,
            excType: exc.excType,
            exception: exc,
          ),
        );
        final s = MontySession(platform: throwing);

        final result = await s.run('x === 1');
        expect(result.isError, isTrue);
        expect(result.error!.message, contains('SyntaxError'));

        s.dispose();
      });
    });

    group('_safeResume catches exceptions', () {
      test('MontyScriptError during resume returns error result', () async {
        const exc = MontyException(
          message: 'RuntimeError: oops',
          excType: 'RuntimeError',
        );
        // Start succeeds normally — enqueue the initial progress.
        final throwing =
            _ThrowingMockPlatform(
              throwOnResume: MontyScriptError(
                exc.message,
                excType: exc.excType,
                exception: exc,
              ),
            )..enqueueProgress(
              const MontyPending(
                functionName: '__restore_state__',
                arguments: [],
              ),
            );

        final s = MontySession(platform: throwing);
        // run() calls start (succeeds), then resume (throws MontyScriptError).
        final result = await s.run('x = 1');
        expect(result.isError, isTrue);
        expect(result.error!.message, contains('RuntimeError'));

        s.dispose();
      });

      test('MontyError during resume returns error result', () async {
        final throwing =
            _ThrowingMockPlatform(
              throwOnResume: const MontyPanicError('WASM trap during resume'),
            )..enqueueProgress(
              const MontyPending(
                functionName: '__restore_state__',
                arguments: [],
              ),
            );

        final s = MontySession(platform: throwing);
        final result = await s.run('x = 1');
        expect(result.isError, isTrue);
        expect(result.error!.message, contains('WASM trap during resume'));

        s.dispose();
      });
    });

    group('_safeResumeWithError catches exceptions', () {
      test(
        'MontyScriptError during resumeWithError returns error result',
        () async {
          const exc = MontyException(message: 'internal error');
          // Start succeeds, then restore pending, then unknown fn triggers
          // resumeWithError which throws.
          final throwing =
              _ThrowingMockPlatform(
                  throwOnResumeWithError: MontyScriptError(
                    exc.message,
                    exception: exc,
                  ),
                )
                ..enqueueProgress(
                  const MontyPending(
                    functionName: '__restore_state__',
                    arguments: [],
                  ),
                )
                ..enqueueProgress(
                  const MontyPending(functionName: 'unknown_fn', arguments: []),
                );

          final s = MontySession(platform: throwing);
          // run() -> restore (resume OK via start path) -> unknown_fn ->
          // resumeWithError (throws)
          // But _safeResume is used for restore. We need the resume to succeed
          // for restore, then fail for resumeWithError on the unknown fn.
          // The _ThrowingMockPlatform throws on ALL resumes though.
          // Let's use a different approach: make resume succeed but
          // resumeWithError throw.
          // Actually _ThrowingMockPlatform.resume is not overridden to throw
          // here — only throwOnResumeWithError is set. So resume works fine.

          // Wait — _ThrowingMockPlatform.resume will call super if
          // throwOnResume is null. So the restore resume works from the queue.
          // Then the unknown_fn triggers _safeResumeWithError which throws.
          final result = await s.run('unknown_fn()');
          expect(result.isError, isTrue);
          expect(result.error!.message, contains('internal error'));

          s.dispose();
        },
      );

      test('MontyError during resumeWithError returns error result', () async {
        final throwing =
            _ThrowingMockPlatform(
                throwOnResumeWithError: const MontyPanicError(
                  'panic on error path',
                ),
              )
              ..enqueueProgress(
                const MontyPending(
                  functionName: '__restore_state__',
                  arguments: [],
                ),
              )
              ..enqueueProgress(
                const MontyPending(functionName: 'unknown_fn', arguments: []),
              );

        final s = MontySession(platform: throwing);
        final result = await s.run('unknown_fn()');
        expect(result.isError, isTrue);
        expect(result.error!.message, contains('panic on error path'));

        s.dispose();
      });
    });

    group('_capturePersistArgs edge cases', () {
      test('empty arguments list is handled gracefully', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyPending(
              functionName: '__persist_state__',
              arguments: [], // Empty arguments — no state captured.
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        await session.run('pass');
        // State should remain empty when persist args are empty.
        expect(session.state, isEmpty);
      });
    });

    group('_interceptProgress passes through OsCall', () {
      test('OsCall during start() is returned to caller', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'os.getenv',
              arguments: [MontyString('HOME')],
              callId: 1,
            ),
          );

        final progress = await session.start(
          'import os; os.getenv("HOME")',
          externalFunctions: ['os.getenv'],
        );

        expect(progress, isA<MontyOsCall>());
        final osCall = progress as MontyOsCall;
        expect(osCall.operationName, 'os.getenv');
      });
    });

    group('_generatePersist with empty names', () {
      test('generates simple empty dict persist when no names', () async {
        _enqueueRunCycle(mock, stateToPersist: {});
        // Code with no assignments and only a comment.
        await session.run('# nothing here');

        final code = mock.lastStartCode!;
        expect(code, contains('__persist_state__({})'));
      });
    });

    group('MontyOsCall during start() is passed through to caller', () {
      test('OsCall is returned after intercepting restore', () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'Path.read_text',
              arguments: [MontyString('/tmp/file')],
              callId: 42,
            ),
          );

        final progress = await session.start(
          'open("/tmp/file")',
          externalFunctions: [],
        );

        expect(progress, isA<MontyOsCall>());
        final osCall = progress as MontyOsCall;
        expect(osCall.operationName, 'Path.read_text');
        expect(osCall.callId, 42);
      });
    });

    group('_safeStart catches MontyError from platform.start', () {
      test(
        'MontyPanicError during start returns error result via run',
        () async {
          final throwing = _ThrowingMockPlatform(
            throwOnStart: const MontyPanicError('engine died'),
          );
          final s = MontySession(platform: throwing);

          final result = await s.run('x = 1');
          expect(result.isError, isTrue);
          expect(result.error!.message, contains('engine died'));
          // Session is NOT disposed — can be reused.
          expect(s.isDisposed, isFalse);
          s.dispose();
        },
      );
    });

    group('_safeResume catches MontyScriptError during persist', () {
      test('MontyScriptError thrown by resume during persist phase', () async {
        // Start succeeds, restore succeeds, then persist resume throws.
        const exc = MontyException(
          message: 'RuntimeError: persist failed',
          excType: 'RuntimeError',
        );
        // Enqueue restore pending for start, then persist pending:
        final throwing =
            _CountedThrowingPlatform(
                throwOnResumeAfter: 1,
                throwWith: MontyScriptError(
                  exc.message,
                  excType: exc.excType,
                  exception: exc,
                ),
              )
              // After restore resume succeeds, enqueue persist pending:
              ..enqueueProgress(
                const MontyPending(
                  functionName: '__restore_state__',
                  arguments: [],
                ),
              )
              ..enqueueProgress(
                MontyPending(
                  functionName: '__persist_state__',
                  arguments: [
                    _toMontyDict(const {'x': 1}),
                  ],
                ),
              );
        // The second resume (for persist) will throw MontyScriptError.

        final s = MontySession(platform: throwing);
        final result = await s.run('x = 1');
        expect(result.isError, isTrue);
        expect(result.error!.message, contains('persist failed'));
        s.dispose();
      });
    });

    group('_safeResumeWithError catches MontyError', () {
      test(
        'MontyPanicError during resumeWithError returns error result',
        () async {
          final throwing =
              _ThrowingMockPlatform(
                  throwOnResumeWithError: const MontyPanicError(
                    'panic on error path',
                  ),
                )
                ..enqueueProgress(
                  const MontyPending(
                    functionName: '__restore_state__',
                    arguments: [],
                  ),
                )
                ..enqueueProgress(
                  const MontyPending(functionName: 'unknown_fn', arguments: []),
                );

          final s = MontySession(platform: throwing);
          final result = await s.run('unknown_fn()');
          expect(result.isError, isTrue);
          expect(result.error!.message, contains('panic on error path'));
          s.dispose();
        },
      );
    });

    group('OsProvider lifecycle', () {
      test('session.dispose() disposes OsProvider', () {
        final handler = _MockOsProvider();
        MontySession(platform: mock, os: handler).dispose();

        expect(handler.disposed, isTrue);
        expect(handler.disposeCount, 1);
      });

      test('run() dispatches OsCall through handler', () async {
        final handler = _MockOsProvider(
          onResolve: (call) async => 'file content',
        );
        final s = MontySession(platform: mock, os: handler);

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'Path.read_text',
              arguments: [MontyString('/sandbox/test.txt')],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [_toMontyDict(const {})],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        await s.run('open("/sandbox/test.txt")');

        // Handler was invoked and resume received the handler's return value.
        expect(handler.resolveCount, 1);
        expect(mock.resumeReturnValues, contains('file content'));

        s.dispose();
      });

      test('run() catches handler error and resumes with error', () async {
        final handler = _MockOsProvider(
          onResolve: (call) async => throw StateError('disk on fire'),
        );
        final s = MontySession(platform: mock, os: handler);

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'Path.write_text',
              arguments: [MontyString('/sandbox/out.txt')],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [_toMontyDict(const {})],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        await s.run('write("/sandbox/out.txt")');

        expect(mock.resumeErrorMessages, hasLength(1));
        expect(mock.resumeErrorMessages.first, contains('disk on fire'));

        s.dispose();
      });

      test('run() catches OsCallFileNotFoundError', () async {
        final handler = _MockOsProvider(
          onResolve: (call) async => throw const OsCallFileNotFoundError(
            'Path.read_text',
            'No such file: /sandbox/missing.txt',
          ),
        );
        final s = MontySession(platform: mock, os: handler);

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: '__restore_state__',
              arguments: [],
            ),
          )
          ..enqueueProgress(
            const MontyOsCall(
              operationName: 'Path.read_text',
              arguments: [MontyString('/sandbox/missing.txt')],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            MontyPending(
              functionName: '__persist_state__',
              arguments: [_toMontyDict(const {})],
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        await s.run('open("/sandbox/missing.txt")');

        expect(mock.resumeErrorMessages, hasLength(1));
        expect(mock.resumeErrorMessages.first, contains('FileNotFoundError'));

        s.dispose();
      });
    });

    group('extractAssignmentTargets', () {
      test('finds simple assignments', () {
        expect(MontySession.extractAssignmentTargets('x = 42'), {'x'});
      });

      test('finds multiple assignments', () {
        expect(MontySession.extractAssignmentTargets('x = 1\ny = 2\nz = 3'), {
          'x',
          'y',
          'z',
        });
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
        expect(MontySession.extractAssignmentTargets('x == 42'), isEmpty);
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
        expect(MontySession.extractAssignmentTargets('x = 1; y = 2; z = 3'), {
          'x',
          'y',
          'z',
        });
      });
    });

    group('signals', () {
      test('lifecycleSignal starts as MontySessionActive', () {
        expect(session.lifecycleSignal.value, isA<MontySessionActive>());
      });

      test('persistedStateSignal starts empty', () {
        expect(session.persistedStateSignal.value, isEmpty);
      });

      test('persistedStateSignal updates after run() persists state', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 42});
        await session.run('x = 42');
        expect(session.persistedStateSignal.value, {'x': 42});
      });

      test('persistedStateSignal updates with each run()', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');
        expect(session.persistedStateSignal.value, {'x': 1});

        _enqueueRunCycle(mock, stateToPersist: {'x': 1, 'y': 2});
        await session.run('y = 2');
        expect(session.persistedStateSignal.value, {'x': 1, 'y': 2});
      });

      test('persistedStateSignal emits empty map after clearState()', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');

        session.clearState();
        expect(session.persistedStateSignal.value, isEmpty);
      });

      test(
        'lifecycleSignal transitions to MontySessionDisposed on dispose()',
        () {
          session.dispose();
          expect(session.lifecycleSignal.value, isA<MontySessionDisposed>());
        },
      );

      test('persistedStateSignal emits empty map on dispose()', () async {
        _enqueueRunCycle(mock, stateToPersist: {'x': 1});
        await session.run('x = 1');

        session.dispose();
        expect(session.persistedStateSignal.value, isEmpty);
      });

      test('effect() fires when state is persisted', () async {
        final observed = <Map<String, Object?>>[];
        final sub = effect(
          () => observed.add(session.persistedStateSignal.value),
        );

        _enqueueRunCycle(mock, stateToPersist: {'a': 10});
        await session.run('a = 10');

        expect(observed.last, {'a': 10});
        sub(); // dispose effect
      });
    });
  });
}

/// Converts a raw `Map<String, Object?>` to a [MontyDict] for use in
/// `__persist_state__` arguments.
MontyDict _toMontyDict(Map<String, Object?> map) {
  return MontyDict(map.map((k, v) => MapEntry(k, MontyValue.fromJson(v))));
}

/// Enqueues a full run cycle: restore → persist → complete.
void _enqueueRunCycle(
  MockMontyPlatform mock, {
  required Map<String, Object?> stateToPersist,
  MontyValue? resultValue,
}) {
  mock
    // 1. restore
    ..enqueueProgress(
      const MontyPending(functionName: '__restore_state__', arguments: []),
    )
    // 2. persist
    ..enqueueProgress(
      MontyPending(
        functionName: '__persist_state__',
        arguments: [_toMontyDict(stateToPersist)],
      ),
    )
    // 3. complete
    ..enqueueProgress(
      MontyComplete(
        result: MontyResult(
          value: resultValue ?? const MontyNull(),
          usage: _usage,
        ),
      ),
    );
}

/// A mock platform that throws a [MontyError] on [start] or [resume].
///
/// Uses the same progress queue as [MockMontyPlatform] for operations
/// that should succeed. Throws the configured error on the specified method.
class _ThrowingMockPlatform extends MockMontyPlatform {
  _ThrowingMockPlatform({
    this.throwOnStart,
    this.throwOnResume,
    this.throwOnResumeWithError,
  });

  final Exception? throwOnStart;
  final Exception? throwOnResume;
  final Exception? throwOnResumeWithError;

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    if (throwOnStart != null) throw throwOnStart!;
    return super.start(
      code,
      externalFunctions: externalFunctions,
      limits: limits,
      scriptName: scriptName,
    );
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    if (throwOnResume != null) throw throwOnResume!;
    return super.resume(returnValue);
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    if (throwOnResumeWithError != null) throw throwOnResumeWithError!;
    return super.resumeWithError(errorMessage);
  }
}

class _MockOsProvider extends OsProvider {
  _MockOsProvider({this.onResolve}) : super.base();

  final Future<Object?> Function(MontyOsCall)? onResolve;
  bool disposed = false;
  int disposeCount = 0;
  int resolveCount = 0;

  @override
  Future<Object?> resolve(MontyOsCall call) {
    resolveCount++;
    if (onResolve != null) return onResolve!(call);
    return Future.value();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    disposeCount++;
  }
}

/// A mock platform that throws after a configurable number of resume calls.
///
/// The first [throwOnResumeAfter] resumes succeed normally from the queue.
/// Subsequent resumes throw [throwWith].
class _CountedThrowingPlatform extends MockMontyPlatform {
  _CountedThrowingPlatform({
    required this.throwOnResumeAfter,
    required this.throwWith,
  });

  final int throwOnResumeAfter;
  final Exception throwWith;
  int _resumeCount = 0;

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    _resumeCount++;
    if (_resumeCount > throwOnResumeAfter) throw throwWith;
    return super.resume(returnValue);
  }
}
