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
