import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:test/test.dart';

void main() {
  group('MockMontyPlatform', () {
    late MockMontyPlatform mock;

    const usage = MontyResourceUsage(
      memoryBytesUsed: 100,
      timeElapsedMs: 10,
      stackDepthUsed: 1,
    );

    setUp(() {
      mock = MockMontyPlatform();
    });

    test('is a MontyPlatform', () {
      expect(mock, isA<MontyPlatform>());
    });

    test('implements MontySnapshotCapable', () {
      expect(mock, isA<MontySnapshotCapable>());
    });

    test('implements MontyFutureCapable', () {
      expect(mock, isA<MontyFutureCapable>());
    });

    // -----------------------------------------------------------------------
    // run()
    // -----------------------------------------------------------------------

    test('run() throws StateError when runResult is not set', () {
      expect(() => mock.run('code'), throwsStateError);
    });

    test('run() returns result and records invocation history', () async {
      const result = MontyResult(value: MontyInt(42), usage: usage);
      mock.runResult = result;

      final returned = await mock.run(
        '1 + 1',
        limits: const MontyLimits(memoryBytes: 1024),
        scriptName: 'test.py',
      );

      expect(returned, result);
      expect(mock.runCodes, ['1 + 1']);
      expect(mock.lastRunCode, '1 + 1');
      expect(mock.lastRunLimits, const MontyLimits(memoryBytes: 1024));
      expect(mock.lastRunScriptName, 'test.py');
    });

    // -----------------------------------------------------------------------
    // snapshot()
    // -----------------------------------------------------------------------

    test('snapshot() throws StateError when snapshotData not set', () {
      expect(() => mock.snapshot(), throwsStateError);
    });

    test('snapshot() returns data when set', () async {
      final data = Uint8List.fromList([1, 2, 3]);
      mock.snapshotData = data;

      final returned = await mock.snapshot();
      expect(returned, data);
    });

    // -----------------------------------------------------------------------
    // restore()
    // -----------------------------------------------------------------------

    test('restore() throws StateError when restoreResult not set', () {
      expect(() => mock.restore(Uint8List.fromList([1])), throwsStateError);
    });

    test('restore() returns platform and records data', () async {
      final other = MockMontyPlatform();
      mock.restoreResult = other;

      final data = Uint8List.fromList([4, 5, 6]);
      final returned = await mock.restore(data);

      expect(returned, other);
      expect(mock.restoreDataList, [data]);
      expect(mock.lastRestoreData, data);
    });

    // -----------------------------------------------------------------------
    // start() / resume() / resumeWithError()
    // -----------------------------------------------------------------------

    test('start() dequeues progress and records code', () async {
      const pending = MontyPending(functionName: 'fetch', arguments: []);
      mock.enqueueProgress(pending);

      final progress = await mock.start(
        'code',
        externalFunctions: ['fetch'],
        limits: const MontyLimits(timeoutMs: 500),
        scriptName: 'script.py',
      );

      expect(progress, pending);
      expect(mock.startCodes, ['code']);
      expect(mock.lastStartCode, 'code');
      expect(mock.lastStartExternalFunctions, ['fetch']);
      expect(mock.lastStartLimits, const MontyLimits(timeoutMs: 500));
      expect(mock.lastStartScriptName, 'script.py');
    });

    test('resume() dequeues progress and records return value', () async {
      const complete = MontyComplete(result: MontyResult(usage: usage));
      mock.enqueueProgress(complete);

      final progress = await mock.resume('hello');

      expect(progress, complete);
      expect(mock.resumeReturnValues, ['hello']);
      expect(mock.lastResumeReturnValue, 'hello');
    });

    test('resumeWithError() dequeues progress and records error', () async {
      const complete = MontyComplete(result: MontyResult(usage: usage));
      mock.enqueueProgress(complete);

      final progress = await mock.resumeWithError('boom');

      expect(progress, complete);
      expect(mock.resumeErrorMessages, ['boom']);
      expect(mock.lastResumeErrorMessage, 'boom');
    });

    // -----------------------------------------------------------------------
    // resumeAsFuture()
    // -----------------------------------------------------------------------

    test('resumeAsFuture() increments count and dequeues', () async {
      const pending = MontyPending(functionName: 'slow_op', arguments: []);
      mock.enqueueProgress(pending);

      expect(mock.resumeAsFutureCount, 0);

      final progress = await mock.resumeAsFuture();

      expect(progress, pending);
      expect(mock.resumeAsFutureCount, 1);
    });

    test('resumeAsFuture() increments on each call', () async {
      mock
        ..enqueueProgress(const MontyPending(functionName: 'a', arguments: []))
        ..enqueueProgress(const MontyPending(functionName: 'b', arguments: []));

      await mock.resumeAsFuture();
      await mock.resumeAsFuture();

      expect(mock.resumeAsFutureCount, 2);
    });

    // -----------------------------------------------------------------------
    // resolveFutures()
    // -----------------------------------------------------------------------

    test('resolveFutures() records results and errors, dequeues', () async {
      const complete = MontyComplete(result: MontyResult(usage: usage));
      mock.enqueueProgress(complete);

      final results = {1: 'value1' as Object?, 2: 42 as Object?};
      final errors = {3: 'timeout'};

      final progress = await mock.resolveFutures(results, errors: errors);

      expect(progress, complete);
      expect(mock.resolveFuturesResultsList, [results]);
      expect(mock.lastResolveFuturesResults, results);
      expect(mock.resolveFuturesErrorsList, [errors]);
      expect(mock.lastResolveFuturesErrors, errors);
    });

    // -----------------------------------------------------------------------
    // enqueueProgress + FIFO order
    // -----------------------------------------------------------------------

    test('enqueueProgress dequeues in FIFO order', () async {
      const first = MontyPending(functionName: 'a', arguments: []);
      const second = MontyPending(functionName: 'b', arguments: []);
      const third = MontyComplete(result: MontyResult(usage: usage));

      mock
        ..enqueueProgress(first)
        ..enqueueProgress(second)
        ..enqueueProgress(third);

      // start consumes first
      final p1 = await mock.start('code');
      expect(p1, first);

      // resume consumes second
      final p2 = await mock.resume(null);
      expect(p2, second);

      // resume consumes third
      final p3 = await mock.resume(null);
      expect(p3, third);
    });

    // -----------------------------------------------------------------------
    // _dequeueProgress throws when empty
    // -----------------------------------------------------------------------

    test('start() throws StateError when progress queue is empty', () {
      expect(() => mock.start('code'), throwsStateError);
    });

    test('resume() throws StateError when progress queue is empty', () {
      expect(() => mock.resume(null), throwsStateError);
    });

    test('resumeWithError() throws StateError when queue is empty', () {
      expect(() => mock.resumeWithError('err'), throwsStateError);
    });

    test('resumeAsFuture() throws StateError when queue is empty', () {
      expect(() => mock.resumeAsFuture(), throwsStateError);
    });

    test('resolveFutures() throws StateError when queue is empty', () {
      expect(() => mock.resolveFutures({}), throwsStateError);
    });

    // -----------------------------------------------------------------------
    // dispose()
    // -----------------------------------------------------------------------

    test('dispose() sets isDisposed to true', () async {
      await mock.dispose();
      expect(mock.isDisposed, isTrue);
    });

    // -----------------------------------------------------------------------
    // Convenience getters return null when empty
    // -----------------------------------------------------------------------

    test('convenience getters return null when no calls recorded', () {
      expect(mock.lastRunCode, isNull);
      expect(mock.lastRunLimits, isNull);
      expect(mock.lastRunScriptName, isNull);
      expect(mock.lastStartCode, isNull);
      expect(mock.lastStartExternalFunctions, isNull);
      expect(mock.lastStartLimits, isNull);
      expect(mock.lastStartScriptName, isNull);
      expect(mock.lastResumeReturnValue, isNull);
      expect(mock.lastResumeErrorMessage, isNull);
      expect(mock.lastResolveFuturesResults, isNull);
      expect(mock.lastResolveFuturesErrors, isNull);
      expect(mock.lastRestoreData, isNull);
    });
  });
}
