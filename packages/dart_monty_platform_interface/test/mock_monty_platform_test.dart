import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 100,
    timeElapsedMs: 5,
    stackDepthUsed: 1,
  );

  group('MockMontyPlatform', () {
    late MockMontyPlatform mock;

    setUp(() {
      mock = MockMontyPlatform();
    });

    tearDown(MontyPlatform.resetInstance);

    test('can be registered as MontyPlatform.instance', () {
      MontyPlatform.instance = mock;
      expect(MontyPlatform.instance, mock);
    });

    group('run', () {
      test('returns configured result', () async {
        const expected = MontyResult(value: 42, usage: usage);
        mock.runResult = expected;
        final result = await mock.run('1 + 1');
        expect(result, expected);
      });

      test('captures code', () async {
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('print("hello")');
        expect(mock.lastRunCode, 'print("hello")');
      });

      test('captures inputs', () async {
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('x', inputs: {'x': 42});
        expect(mock.lastRunInputs, {'x': 42});
      });

      test('captures limits', () async {
        const limits = MontyLimits(timeoutMs: 1000);
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('x', limits: limits);
        expect(mock.lastRunLimits, limits);
      });

      test('throws StateError when runResult not set', () {
        expect(
          () => mock.run('code'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('runResult not set'),
            ),
          ),
        );
      });
    });

    group('start', () {
      test('returns enqueued progress', () async {
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: ['url'],
        );
        mock.enqueueProgress(pending);
        final progress = await mock.start('code');
        expect(progress, pending);
      });

      test('captures code', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.start('my_code');
        expect(mock.lastStartCode, 'my_code');
      });

      test('captures inputs', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.start('code', inputs: {'a': 1});
        expect(mock.lastStartInputs, {'a': 1});
      });

      test('captures external functions', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.start('code', externalFunctions: ['fn1', 'fn2']);
        expect(mock.lastStartExternalFunctions, ['fn1', 'fn2']);
      });

      test('captures limits', () async {
        const limits = MontyLimits(memoryBytes: 2048);
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.start('code', limits: limits);
        expect(mock.lastStartLimits, limits);
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.start('code'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('No progress enqueued'),
            ),
          ),
        );
      });
    });

    group('resume', () {
      test('returns enqueued progress', () async {
        const complete = MontyComplete(
          result: MontyResult(value: 'done', usage: usage),
        );
        mock.enqueueProgress(complete);
        final progress = await mock.resume(42);
        expect(progress, complete);
      });

      test('captures return value', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.resume('result');
        expect(mock.lastResumeReturnValue, 'result');
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.resume(null),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('resumeWithError', () {
      test('returns enqueued progress', () async {
        const complete = MontyComplete(
          result: MontyResult(
            error: MontyException(message: 'oops'),
            usage: usage,
          ),
        );
        mock.enqueueProgress(complete);
        final progress = await mock.resumeWithError('oops');
        expect(progress, complete);
      });

      test('captures error message', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.resumeWithError('bad input');
        expect(mock.lastResumeErrorMessage, 'bad input');
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.resumeWithError('err'),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('snapshot', () {
      test('returns configured data', () async {
        final data = Uint8List.fromList([1, 2, 3]);
        mock.snapshotData = data;
        final result = await mock.snapshot();
        expect(result, data);
      });

      test('throws StateError when not configured', () {
        expect(
          () => mock.snapshot(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('snapshotData not set'),
            ),
          ),
        );
      });
    });

    group('restore', () {
      test('returns configured platform', () async {
        final restored = MockMontyPlatform();
        mock.restoreResult = restored;
        final result = await mock.restore(Uint8List.fromList([4, 5, 6]));
        expect(result, restored);
      });

      test('captures restore data', () async {
        final data = Uint8List.fromList([7, 8, 9]);
        mock.restoreResult = MockMontyPlatform();
        await mock.restore(data);
        expect(mock.lastRestoreData, data);
      });

      test('throws StateError when not configured', () {
        expect(
          () => mock.restore(Uint8List(0)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('restoreResult not set'),
            ),
          ),
        );
      });
    });

    group('dispose', () {
      test('starts as not disposed', () {
        expect(mock.isDisposed, isFalse);
      });

      test('marks as disposed', () async {
        await mock.dispose();
        expect(mock.isDisposed, isTrue);
      });
    });

    group('queue workflow', () {
      test('processes FIFO order', () async {
        const pending = MontyPending(
          functionName: 'step1',
          arguments: [],
        );
        const complete = MontyComplete(
          result: MontyResult(value: 'final', usage: usage),
        );

        mock
          ..enqueueProgress(pending)
          ..enqueueProgress(complete);

        final first = await mock.start('code', externalFunctions: ['step1']);
        expect(first, isA<MontyPending>());

        final second = await mock.resume(42);
        expect(second, isA<MontyComplete>());
      });

      test('queue empty after all consumed', () async {
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(usage: usage),
          ),
        );
        await mock.start('code');

        expect(
          () => mock.resume(null),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}
