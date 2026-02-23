import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
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
        expect(mock.runCodes, ['print("hello")']);
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

      test('captures scriptName', () async {
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('x', scriptName: 'helper.py');
        expect(mock.lastRunScriptName, 'helper.py');
        expect(mock.runScriptNamesList, ['helper.py']);
      });

      test('captures null scriptName', () async {
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('x');
        expect(mock.lastRunScriptName, isNull);
        expect(mock.runScriptNamesList, [null]);
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

      test('records multiple invocations', () async {
        mock.runResult = const MontyResult(usage: usage);
        await mock.run('first');
        await mock.run('second', inputs: {'a': 1});
        await mock.run('third');

        expect(mock.runCodes, ['first', 'second', 'third']);
        expect(mock.runInputsList, [
          null,
          {'a': 1},
          null,
        ]);
        expect(mock.lastRunCode, 'third');
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
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('my_code');
        expect(mock.lastStartCode, 'my_code');
        expect(mock.startCodes, ['my_code']);
      });

      test('captures inputs', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('code', inputs: {'a': 1});
        expect(mock.lastStartInputs, {'a': 1});
      });

      test('captures external functions', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('code', externalFunctions: ['fn1', 'fn2']);
        expect(mock.lastStartExternalFunctions, ['fn1', 'fn2']);
      });

      test('captures limits', () async {
        const limits = MontyLimits(memoryBytes: 2048);
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('code', limits: limits);
        expect(mock.lastStartLimits, limits);
      });

      test('captures scriptName', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('code', scriptName: 'pipeline_step1.py');
        expect(mock.lastStartScriptName, 'pipeline_step1.py');
        expect(mock.startScriptNamesList, ['pipeline_step1.py']);
      });

      test('captures null scriptName', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.start('code');
        expect(mock.lastStartScriptName, isNull);
        expect(mock.startScriptNamesList, [null]);
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
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.resume('result');
        expect(mock.lastResumeReturnValue, 'result');
        expect(mock.resumeReturnValues, ['result']);
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
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.resumeWithError('bad input');
        expect(mock.lastResumeErrorMessage, 'bad input');
        expect(mock.resumeErrorMessages, ['bad input']);
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
        expect(mock.restoreDataList, [data]);
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

    group('convenience getters return null when empty', () {
      test('lastRunCode', () {
        expect(mock.lastRunCode, isNull);
      });

      test('lastRunInputs', () {
        expect(mock.lastRunInputs, isNull);
      });

      test('lastRunLimits', () {
        expect(mock.lastRunLimits, isNull);
      });

      test('lastRunScriptName', () {
        expect(mock.lastRunScriptName, isNull);
      });

      test('lastStartCode', () {
        expect(mock.lastStartCode, isNull);
      });

      test('lastStartInputs', () {
        expect(mock.lastStartInputs, isNull);
      });

      test('lastStartExternalFunctions', () {
        expect(mock.lastStartExternalFunctions, isNull);
      });

      test('lastStartLimits', () {
        expect(mock.lastStartLimits, isNull);
      });

      test('lastStartScriptName', () {
        expect(mock.lastStartScriptName, isNull);
      });

      test('lastResumeReturnValue', () {
        expect(mock.lastResumeReturnValue, isNull);
      });

      test('lastResumeErrorMessage', () {
        expect(mock.lastResumeErrorMessage, isNull);
      });

      test('lastRestoreData', () {
        expect(mock.lastRestoreData, isNull);
      });

      test('lastResolveFuturesResults', () {
        expect(mock.lastResolveFuturesResults, isNull);
      });

      test('lastResolveFuturesWithErrorsResults', () {
        expect(mock.lastResolveFuturesWithErrorsResults, isNull);
      });

      test('lastResolveFuturesWithErrorsErrors', () {
        expect(mock.lastResolveFuturesWithErrorsErrors, isNull);
      });
    });

    group('resumeAsFuture', () {
      test('returns enqueued progress', () async {
        const futures = MontyResolveFutures(pendingCallIds: [0]);
        mock.enqueueProgress(futures);
        final progress = await mock.resumeAsFuture();
        expect(progress, futures);
      });

      test('increments call count', () async {
        mock.enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [0]),
        );
        expect(mock.resumeAsFutureCount, 0);
        await mock.resumeAsFuture();
        expect(mock.resumeAsFutureCount, 1);
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.resumeAsFuture(),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('resolveFutures', () {
      test('returns enqueued progress', () async {
        const complete = MontyComplete(
          result: MontyResult(value: 'done', usage: usage),
        );
        mock.enqueueProgress(complete);
        final progress = await mock.resolveFutures({0: 'value'});
        expect(progress, complete);
      });

      test('captures results', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.resolveFutures({0: 'a', 1: 42});
        expect(mock.lastResolveFuturesResults, {0: 'a', 1: 42});
        expect(mock.resolveFuturesResultsList, [
          {0: 'a', 1: 42},
        ]);
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.resolveFutures({0: 'x'}),
          throwsA(isA<StateError>()),
        );
      });
    });

    group('resolveFuturesWithErrors', () {
      test('returns enqueued progress', () async {
        const complete = MontyComplete(
          result: MontyResult(
            error: MontyException(message: 'fail'),
            usage: usage,
          ),
        );
        mock.enqueueProgress(complete);
        final progress = await mock.resolveFuturesWithErrors(
          {0: 'ok'},
          {1: 'fail'},
        );
        expect(progress, complete);
      });

      test('captures results and errors', () async {
        mock.enqueueProgress(
          const MontyComplete(result: MontyResult(usage: usage)),
        );
        await mock.resolveFuturesWithErrors({0: 10}, {1: 'timeout'});
        expect(mock.lastResolveFuturesWithErrorsResults, {0: 10});
        expect(mock.lastResolveFuturesWithErrorsErrors, {1: 'timeout'});
      });

      test('throws StateError when queue empty', () {
        expect(
          () => mock.resolveFuturesWithErrors({}, {}),
          throwsA(isA<StateError>()),
        );
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
          const MontyComplete(result: MontyResult(usage: usage)),
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
