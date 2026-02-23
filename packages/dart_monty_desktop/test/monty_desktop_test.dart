import 'dart:typed_data';

import 'package:dart_monty_desktop/src/desktop_bindings.dart';
import 'package:dart_monty_desktop/src/monty_desktop.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_desktop_bindings.dart';

void main() {
  late MockDesktopBindings mock;
  late MontyDesktop monty;

  setUp(() {
    mock = MockDesktopBindings();
    monty = MontyDesktop(bindings: mock);
  });

  tearDown(() async {
    await monty.dispose();
  });

  // ===========================================================================
  // initialize()
  // ===========================================================================
  group('initialize()', () {
    test('calls bindings.init()', () async {
      await monty.initialize();
      expect(mock.initCalls, 1);
    });

    test('is idempotent', () async {
      await monty.initialize();
      await monty.initialize();
      expect(mock.initCalls, 1);
    });

    test('throws StateError on init failure', () async {
      mock.nextInitResult = false;
      expect(monty.initialize, throwsStateError);
    });
  });

  // ===========================================================================
  // run()
  // ===========================================================================
  group('run()', () {
    test('returns result', () async {
      mock.nextRunResult = DesktopRunResult(
        result: MontyResult(
          value: 4,
          usage: _usage(memory: 100, time: 5, stack: 2),
        ),
      );

      final result = await monty.run('2 + 2');

      expect(result.value, 4);
      expect(result.isError, isFalse);
      expect(result.usage.memoryBytesUsed, 100);
      expect(result.usage.timeElapsedMs, 5);
      expect(result.usage.stackDepthUsed, 2);
      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.code, '2 + 2');
    });

    test('auto-initializes on first call', () async {
      await monty.run('1');
      expect(mock.initCalls, 1);
    });

    test('does not re-initialize after first call', () async {
      await monty.run('1');
      await monty.run('2');
      expect(mock.initCalls, 1);
    });

    test('passes limits to bindings', () async {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 500,
        stackDepth: 10,
      );

      await monty.run('x', limits: limits);

      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.limits, limits);
    });

    test('passes null limits when none provided', () async {
      await monty.run('1');
      expect(mock.runCalls.first.limits, isNull);
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => monty.run('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('allows null inputs', () async {
      // Verifying null inputs are accepted without error.
      // ignore: avoid_redundant_argument_values
      final result = await monty.run('1', inputs: null);
      expect(result.value, 4);
    });

    test('allows empty inputs', () async {
      final result = await monty.run('1', inputs: {});
      expect(result.value, 4);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.run('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);

      expect(() => monty.run('y'), throwsStateError);
    });

    test('returns null value', () async {
      mock.nextRunResult = const DesktopRunResult(
        result: MontyResult(usage: _zeroUsage),
      );

      final result = await monty.run('None');
      expect(result.value, isNull);
      expect(result.isError, isFalse);
    });

    test('returns string value', () async {
      mock.nextRunResult = const DesktopRunResult(
        result: MontyResult(value: 'hello', usage: _zeroUsage),
      );

      final result = await monty.run('"hello"');
      expect(result.value, 'hello');
    });
  });

  // ===========================================================================
  // start()
  // ===========================================================================
  group('start()', () {
    test('returns MontyComplete when code completes immediately', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(value: 42, usage: _zeroUsage),
        ),
      );

      final progress = await monty.start('42');

      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.value, 42);
    });

    test('returns MontyPending for external function call', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(
          functionName: 'fetch',
          arguments: ['https://example.com'],
        ),
      );

      final progress = await monty.start(
        'fetch("https://example.com")',
        externalFunctions: ['fetch'],
      );

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'fetch');
      expect(pending.arguments, ['https://example.com']);
      expect(mock.startCalls.first.externalFunctions, ['fetch']);
    });

    test('passes multiple external functions', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'a', arguments: []),
      );

      await monty.start('a()', externalFunctions: ['a', 'b', 'c']);

      expect(mock.startCalls.first.externalFunctions, ['a', 'b', 'c']);
    });

    test('passes null externalFunctions when empty list', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(usage: _zeroUsage),
        ),
      );

      await monty.start('x', externalFunctions: []);

      expect(mock.startCalls.first.externalFunctions, isEmpty);
    });

    test('passes null externalFunctions when null', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(usage: _zeroUsage),
        ),
      );

      await monty.start('x');

      expect(mock.startCalls.first.externalFunctions, isNull);
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => monty.start('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.start('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'f', arguments: []),
      );
      await monty.start('x', externalFunctions: ['f']);

      expect(() => monty.start('y'), throwsStateError);
    });

    test('applies limits', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(usage: _zeroUsage),
        ),
      );
      const limits = MontyLimits(memoryBytes: 512);

      await monty.start('x', limits: limits);

      expect(mock.startCalls.first.limits, limits);
    });
  });

  // ===========================================================================
  // resume()
  // ===========================================================================
  group('resume()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete when execution finishes', () async {
      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(value: 'hello', usage: _zeroUsage),
          ),
        ),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeCalls, hasLength(1));
      expect(mock.resumeCalls.first, 'response');
    });

    test('returns MontyPending for another external call', () async {
      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyPending(functionName: 'save', arguments: ['data']),
        ),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'save');
      expect(pending.arguments, ['data']);
    });

    test('throws StateError when idle', () async {
      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(usage: _zeroUsage),
          ),
        ),
      );
      await monty.resume(null);

      expect(() => monty.resume(null), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resume(null), throwsStateError);
    });

    test('passes complex return values', () async {
      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(usage: _zeroUsage),
          ),
        ),
      );

      await monty.resume({
        'key': [1, 2, 3],
      });

      expect(mock.resumeCalls.first, {
        'key': [1, 2, 3],
      });
    });
  });

  // ===========================================================================
  // resumeWithError()
  // ===========================================================================
  group('resumeWithError()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete after error injection', () async {
      mock.resumeWithErrorResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(usage: _zeroUsage),
          ),
        ),
      );

      final progress = await monty.resumeWithError('network failure');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeWithErrorCalls, hasLength(1));
      expect(mock.resumeWithErrorCalls.first, 'network failure');
    });

    test('returns MontyPending for continuation', () async {
      mock.resumeWithErrorResults.add(
        const DesktopProgressResult(
          progress: MontyPending(functionName: 'retry', arguments: []),
        ),
      );

      final progress = await monty.resumeWithError('timeout');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'retry');
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyDesktop(bindings: mock);
      expect(
        () => freshMonty.resumeWithError('err'),
        throwsStateError,
      );
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(
        () => monty.resumeWithError('err'),
        throwsStateError,
      );
    });
  });

  // ===========================================================================
  // resumeAsFuture()
  // ===========================================================================
  group('resumeAsFuture()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyResolveFutures', () async {
      mock.resumeAsFutureResults.add(
        const DesktopProgressResult(
          progress: MontyResolveFutures(pendingCallIds: [0]),
        ),
      );

      final progress = await monty.resumeAsFuture();

      expect(progress, isA<MontyResolveFutures>());
      final resolve = progress as MontyResolveFutures;
      expect(resolve.pendingCallIds, [0]);
      expect(mock.resumeAsFutureCalls, 1);
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyDesktop(bindings: mock);
      expect(freshMonty.resumeAsFuture, throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(monty.resumeAsFuture, throwsStateError);
    });
  });

  // ===========================================================================
  // resolveFutures()
  // ===========================================================================
  group('resolveFutures()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);
      mock.resumeAsFutureResults.add(
        const DesktopProgressResult(
          progress: MontyResolveFutures(pendingCallIds: [0]),
        ),
      );
      await monty.resumeAsFuture();
    });

    test('returns MontyComplete after resolving', () async {
      mock.resolveFuturesResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(value: 'done', usage: _zeroUsage),
          ),
        ),
      );

      final progress = await monty.resolveFutures({0: 'result'});

      expect(progress, isA<MontyComplete>());
      expect(mock.resolveFuturesCalls, hasLength(1));
      expect(mock.resolveFuturesCalls.first, {0: 'result'});
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyDesktop(bindings: mock);
      expect(() => freshMonty.resolveFutures({0: 'x'}), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resolveFutures({0: 'x'}), throwsStateError);
    });
  });

  // ===========================================================================
  // resolveFuturesWithErrors()
  // ===========================================================================
  group('resolveFuturesWithErrors()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'fetch', arguments: []),
      );
      await monty.start('x', externalFunctions: ['fetch']);
      mock.resumeAsFutureResults.add(
        const DesktopProgressResult(
          progress: MontyResolveFutures(pendingCallIds: [0, 1]),
        ),
      );
      await monty.resumeAsFuture();
    });

    test('returns MontyComplete after resolving with errors', () async {
      mock.resolveFuturesWithErrorsResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(value: 'partial', usage: _zeroUsage),
          ),
        ),
      );

      final progress = await monty.resolveFuturesWithErrors(
        {0: 'ok'},
        {1: 'network error'},
      );

      expect(progress, isA<MontyComplete>());
      expect(mock.resolveFuturesWithErrorsCalls, hasLength(1));
      expect(mock.resolveFuturesWithErrorsCalls.first.results, {0: 'ok'});
      expect(
        mock.resolveFuturesWithErrorsCalls.first.errors,
        {1: 'network error'},
      );
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyDesktop(bindings: mock);
      expect(
        () => freshMonty.resolveFuturesWithErrors({}, {}),
        throwsStateError,
      );
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(
        () => monty.resolveFuturesWithErrors({}, {}),
        throwsStateError,
      );
    });
  });

  // ===========================================================================
  // snapshot()
  // ===========================================================================
  group('snapshot()', () {
    setUp(() async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'f', arguments: []),
      );
      await monty.start('x', externalFunctions: ['f']);
    });

    test('returns snapshot bytes', () async {
      mock.nextSnapshotData = Uint8List.fromList([10, 20, 30]);

      final data = await monty.snapshot();

      expect(data, Uint8List.fromList([10, 20, 30]));
      expect(mock.snapshotCalls, 1);
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyDesktop(bindings: mock);
      expect(freshMonty.snapshot, throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.snapshot(), throwsStateError);
    });
  });

  // ===========================================================================
  // restore()
  // ===========================================================================
  group('restore()', () {
    test('returns new MontyDesktop instance', () async {
      final data = Uint8List.fromList([1, 2, 3]);

      final restored = await monty.restore(data);

      expect(restored, isA<MontyDesktop>());
      expect(mock.restoreCalls, hasLength(1));
      expect(mock.restoreCalls.first, data);
    });

    test('restored instance can run code', () async {
      mock.nextRunResult = const DesktopRunResult(
        result: MontyResult(value: 10, usage: _zeroUsage),
      );

      final restored = await monty.restore(Uint8List.fromList([1, 2, 3]));
      final result = await (restored as MontyDesktop).run('5 + 5');

      expect(result.value, 10);
    });

    test('throws MontyException when restore fails', () {
      mock.nextRestoreError = 'invalid snapshot';

      expect(
        () => monty.restore(Uint8List.fromList([0xFF])),
        throwsA(isA<MontyException>()),
      );
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(
        () => monty.restore(Uint8List.fromList([1])),
        throwsStateError,
      );
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'f', arguments: []),
      );
      await monty.start('x', externalFunctions: ['f']);

      expect(
        () => monty.restore(Uint8List.fromList([1])),
        throwsStateError,
      );
    });
  });

  // ===========================================================================
  // dispose()
  // ===========================================================================
  group('dispose()', () {
    test('calls bindings dispose when initialized', () async {
      await monty.initialize();
      await monty.dispose();
      expect(mock.disposeCalls, 1);
    });

    test('does not call bindings dispose when not initialized', () async {
      await monty.dispose();
      expect(mock.disposeCalls, 0);
    });

    test('double dispose is safe', () async {
      await monty.initialize();
      await monty.dispose();
      await monty.dispose();

      expect(mock.disposeCalls, 1);
    });

    test('disposed instance rejects all methods', () async {
      await monty.dispose();

      expect(() => monty.run('x'), throwsStateError);
      expect(() => monty.start('x'), throwsStateError);
      expect(() => monty.resume(null), throwsStateError);
      expect(() => monty.resumeWithError('e'), throwsStateError);
      expect(() => monty.resumeAsFuture(), throwsStateError);
      expect(() => monty.resolveFutures({0: 'x'}), throwsStateError);
      expect(() => monty.resolveFuturesWithErrors({}, {}), throwsStateError);
      expect(() => monty.snapshot(), throwsStateError);
      expect(() => monty.restore(Uint8List(0)), throwsStateError);
    });
  });

  // ===========================================================================
  // State machine transitions
  // ===========================================================================
  group('state machine', () {
    test('idle -> run -> idle', () async {
      await monty.run('1');

      mock.nextRunResult = const DesktopRunResult(
        result: MontyResult(value: 2, usage: _zeroUsage),
      );
      final result = await monty.run('2');
      expect(result.value, 2);
    });

    test('idle -> start(complete) -> idle', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(value: 42, usage: _zeroUsage),
        ),
      );

      await monty.start('42');

      mock.nextRunResult = const DesktopRunResult(
        result: MontyResult(value: 1, usage: _zeroUsage),
      );
      final result = await monty.run('1');
      expect(result.value, 1);
    });

    test(
      'idle -> start(pending) -> active -> resume(complete) -> idle',
      () async {
        mock.nextStartResult = const DesktopProgressResult(
          progress: MontyPending(functionName: 'f', arguments: []),
        );

        await monty.start('x', externalFunctions: ['f']);

        mock.resumeResults.add(
          const DesktopProgressResult(
            progress: MontyComplete(
              result: MontyResult(value: 'done', usage: _zeroUsage),
            ),
          ),
        );

        final progress = await monty.resume('value');
        expect(progress, isA<MontyComplete>());

        mock.nextRunResult = const DesktopRunResult(
          result: MontyResult(value: 1, usage: _zeroUsage),
        );
        final result = await monty.run('1');
        expect(result.value, 1);
      },
    );

    test('active -> resume(pending) -> still active', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'a', arguments: []),
      );
      await monty.start('x', externalFunctions: ['a', 'b']);

      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyPending(functionName: 'b', arguments: ['arg']),
        ),
      );

      final progress = await monty.resume('val');
      expect(progress, isA<MontyPending>());

      mock.resumeResults.add(
        const DesktopProgressResult(
          progress: MontyComplete(
            result: MontyResult(usage: _zeroUsage),
          ),
        ),
      );
      final done = await monty.resume('val2');
      expect(done, isA<MontyComplete>());
    });

    test('active -> dispose -> disposed', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'f', arguments: []),
      );
      await monty.start('x', externalFunctions: ['f']);

      await monty.dispose();

      expect(() => monty.run('x'), throwsStateError);
    });

    test('idle -> dispose -> disposed', () async {
      await monty.dispose();
      expect(() => monty.run('x'), throwsStateError);
    });
  });

  // ===========================================================================
  // Edge cases
  // ===========================================================================
  group('edge cases', () {
    test('pending with empty arguments', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyPending(functionName: 'noop', arguments: []),
      );

      final progress = await monty.start(
        'noop()',
        externalFunctions: ['noop'],
      );

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('complete with null value', () async {
      mock.nextStartResult = const DesktopProgressResult(
        progress: MontyComplete(
          result: MontyResult(usage: _zeroUsage),
        ),
      );

      final progress = await monty.start('None');

      final complete = progress as MontyComplete;
      expect(complete.result.value, isNull);
    });

    test('resource usage is preserved from bindings', () async {
      mock.nextRunResult = DesktopRunResult(
        result: MontyResult(
          value: 1,
          usage: _usage(memory: 256, time: 10, stack: 3),
        ),
      );

      final result = await monty.run('1');

      expect(result.usage.memoryBytesUsed, 256);
      expect(result.usage.timeElapsedMs, 10);
      expect(result.usage.stackDepthUsed, 3);
    });

    test('partial limits are passed through', () async {
      const limits = MontyLimits(timeoutMs: 300);

      await monty.run('1', limits: limits);

      expect(mock.runCalls.first.limits, limits);
    });
  });
}

const _zeroUsage = MontyResourceUsage(
  memoryBytesUsed: 0,
  timeElapsedMs: 0,
  stackDepthUsed: 0,
);

MontyResourceUsage _usage({
  required int memory,
  required int time,
  required int stack,
}) =>
    MontyResourceUsage(
      memoryBytesUsed: memory,
      timeElapsedMs: time,
      stackDepthUsed: stack,
    );
