import 'dart:typed_data';

import 'package:dart_monty_ffi/src/monty_ffi.dart';
import 'package:dart_monty_ffi/src/native_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

import 'mock_native_bindings.dart';

/// Standard usage JSON for test results.
const _usageJson =
    '{"memory_bytes_used": 100, "time_elapsed_ms": 5, "stack_depth_used": 3}';

/// Builds a complete result JSON string.
String _okResultJson(Object? value) =>
    '{"value": $value, "usage": $_usageJson}';

/// Builds an error result JSON string.
String _errorResultJson(String message) =>
    '{"value": null, "error": {"message": "$message"}, "usage": $_usageJson}';

void main() {
  late MockNativeBindings mock;
  late MontyFfi monty;

  setUp(() {
    mock = MockNativeBindings();
    monty = MontyFfi(bindings: mock);
  });

  tearDown(() async {
    // Ensure cleanup (double-dispose is safe).
    await monty.dispose();
  });

  // ===========================================================================
  // run()
  // ===========================================================================
  group('run()', () {
    test('returns OK result', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(4));

      final result = await monty.run('2 + 2');

      expect(result.value, 4);
      expect(result.isError, isFalse);
      final usage = result.usage;
      expect(usage.memoryBytesUsed, 100);
      expect(usage.timeElapsedMs, 5);
      expect(usage.stackDepthUsed, 3);
      final hasOne = hasLength(1);
      expect(mock.createCalls, hasOne);
      expect(mock.createCalls.first.code, '2 + 2');
      expect(mock.runCalls, hasOne);
      expect(mock.freeCalls, hasOne);
    });

    test('throws MontyException on error result', () async {
      mock.nextRunResult = const RunResult(
        tag: 1,
        errorMessage: 'SyntaxError: invalid syntax',
      );

      expect(
        () => monty.run('def'),
        throwsA(
          isA<MontyException>().having(
            (e) => e.message,
            'message',
            'SyntaxError: invalid syntax',
          ),
        ),
      );
    });

    test('applies resource limits', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(42));

      await monty.run(
        'x',
        limits: const MontyLimits(
          memoryBytes: 1024,
          timeoutMs: 500,
          stackDepth: 10,
        ),
      );

      final hasOne = hasLength(1);
      expect(mock.setMemoryLimitCalls, hasOne);
      expect(mock.setMemoryLimitCalls.first.bytes, 1024);
      expect(mock.setTimeLimitMsCalls, hasOne);
      expect(mock.setTimeLimitMsCalls.first.ms, 500);
      expect(mock.setStackLimitCalls, hasOne);
      expect(mock.setStackLimitCalls.first.depth, 10);
    });

    test('passes scriptName to bindings', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(4));

      await monty.run('2 + 2', scriptName: 'test.py');

      expect(mock.createCalls.first.scriptName, 'test.py');
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => monty.run('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('allows null inputs', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(1));
      // Verifying null inputs are accepted without error.
      // ignore: avoid_redundant_argument_values
      final result = await monty.run('1', inputs: null);
      expect(result.value, 1);
    });

    test('allows empty inputs', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(1));
      final result = await monty.run('1', inputs: {});
      expect(result.value, 1);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.run('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['fetch']);

      expect(() => monty.run('y'), throwsStateError);
    });

    test('frees handle even when run throws', () async {
      mock.nextRunResult = const RunResult(
        tag: 1,
        errorMessage: 'boom',
      );

      try {
        await monty.run('x');
      } on MontyException catch (_) {
        // expected
      }

      expect(mock.freeCalls, hasLength(1));
    });
  });

  // ===========================================================================
  // start()
  // ===========================================================================
  group('start()', () {
    test('returns MontyComplete when code completes immediately', () async {
      mock.nextStartResult = ProgressResult(
        tag: 0,
        resultJson: _okResultJson(42),
        isError: 0,
      );

      final progress = await monty.start('42');

      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.value, 42);
      expect(mock.freeCalls, hasLength(1));
    });

    test('returns MontyPending for external function call', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '["https://example.com"]',
      );

      final progress = await monty.start(
        'fetch("https://example.com")',
        externalFunctions: ['fetch'],
      );

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'fetch');
      expect(pending.arguments, ['https://example.com']);
      expect(mock.createCalls.first.externalFunctions, 'fetch');
    });

    test('passes multiple external functions as comma-separated', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'a',
        argumentsJson: '[]',
      );

      await monty.start(
        'a()',
        externalFunctions: ['a', 'b', 'c'],
      );

      expect(mock.createCalls.first.externalFunctions, 'a,b,c');
    });

    test('passes null external functions when empty list', () async {
      mock.nextStartResult = ProgressResult(
        tag: 0,
        resultJson: _okResultJson(null),
        isError: 0,
      );

      await monty.start('x', externalFunctions: []);

      expect(mock.createCalls.first.externalFunctions, isNull);
    });

    test('returns MontyPending with kwargs', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[1]',
        kwargsJson: '{"timeout": 30}',
      );

      final progress = await monty.start(
        'fetch(1, timeout=30)',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.kwargs, {'timeout': 30});
      expect(pending.arguments, [1]);
    });

    test('returns MontyPending with callId and methodCall', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[]',
        callId: 7,
        methodCall: true,
      );

      final progress = await monty.start(
        'obj.fetch()',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.callId, 7);
      expect(pending.methodCall, isTrue);
    });

    test('defaults kwargs to null when not provided', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[]',
      );

      final progress = await monty.start(
        'fetch()',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.kwargs, isNull);
      expect(pending.callId, 0);
      expect(pending.methodCall, isFalse);
    });

    test('passes scriptName to bindings', () async {
      mock.nextStartResult = ProgressResult(
        tag: 0,
        resultJson: _okResultJson(null),
        isError: 0,
      );

      await monty.start('x', scriptName: 'my_script.py');

      expect(mock.createCalls.first.scriptName, 'my_script.py');
    });

    test('throws MontyException on error progress', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 2,
        errorMessage: 'compilation failed',
      );

      expect(
        () => monty.start('bad code'),
        throwsA(
          isA<MontyException>().having(
            (e) => e.message,
            'message',
            'compilation failed',
          ),
        ),
      );
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
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['f']);

      expect(() => monty.start('y'), throwsStateError);
    });

    test('applies limits before starting', () async {
      mock.nextStartResult = ProgressResult(
        tag: 0,
        resultJson: _okResultJson(null),
        isError: 0,
      );

      await monty.start(
        'x',
        limits: const MontyLimits(memoryBytes: 512),
      );

      expect(mock.setMemoryLimitCalls, hasLength(1));
      expect(mock.setMemoryLimitCalls.first.bytes, 512);
    });
  });

  // ===========================================================================
  // resume()
  // ===========================================================================
  group('resume()', () {
    setUp(() async {
      // Start in active state.
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete when execution finishes', () async {
      mock.resumeResults.add(
        ProgressResult(
          tag: 0,
          resultJson: _okResultJson('"hello"'),
          isError: 0,
        ),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeCalls, hasLength(1));
      expect(mock.resumeCalls.first.valueJson, '"response"');
    });

    test('returns MontyPending for another external call', () async {
      mock.resumeResults.add(
        const ProgressResult(
          tag: 1,
          functionName: 'save',
          argumentsJson: '["data"]',
        ),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'save');
      expect(pending.arguments, ['data']);
    });

    test('throws MontyException on error', () async {
      mock.resumeResults.add(
        const ProgressResult(tag: 2, errorMessage: 'runtime error'),
      );

      expect(
        () => monty.resume(null),
        throwsA(isA<MontyException>()),
      );
    });

    test('throws StateError when idle', () async {
      // Complete the execution first to go back to idle.
      mock.resumeResults.add(
        ProgressResult(
          tag: 0,
          resultJson: _okResultJson(null),
          isError: 0,
        ),
      );
      await monty.resume(null);

      expect(() => monty.resume(null), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resume(null), throwsStateError);
    });

    test('encodes complex return values as JSON', () async {
      mock.resumeResults.add(
        ProgressResult(
          tag: 0,
          resultJson: _okResultJson(null),
          isError: 0,
        ),
      );

      await monty.resume({
        'key': [1, 2, 3],
      });

      expect(mock.resumeCalls.first.valueJson, '{"key":[1,2,3]}');
    });
  });

  // ===========================================================================
  // resumeWithError()
  // ===========================================================================
  group('resumeWithError()', () {
    setUp(() async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete after error injection', () async {
      mock.resumeWithErrorResults.add(
        ProgressResult(
          tag: 0,
          resultJson: _errorResultJson('caught error'),
          isError: 1,
        ),
      );

      final progress = await monty.resumeWithError('network failure');

      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.isError, isTrue);
      expect(mock.resumeWithErrorCalls, hasLength(1));
      expect(mock.resumeWithErrorCalls.first.errorMessage, 'network failure');
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyFfi(bindings: mock);
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
  // snapshot()
  // ===========================================================================
  group('snapshot()', () {
    setUp(() async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['f']);
    });

    test('returns snapshot bytes', () async {
      mock.nextSnapshotData = Uint8List.fromList([10, 20, 30]);

      final data = await monty.snapshot();

      expect(data, Uint8List.fromList([10, 20, 30]));
      expect(mock.snapshotCalls, hasLength(1));
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyFfi(bindings: mock);
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
    test('returns new MontyFfi in active state', () async {
      mock.nextRestoreHandle = 77;
      final data = Uint8List.fromList([1, 2, 3]);

      final restored = await monty.restore(data);

      expect(restored, isA<MontyFfi>());
      expect(mock.restoreCalls, hasLength(1));
      expect(mock.restoreCalls.first, data);
    });

    test('restored instance is in active state', () async {
      mock.nextRestoreHandle = 77;

      final restored = await monty.restore(Uint8List.fromList([1, 2, 3]));
      final restoredFfi = restored as MontyFfi;

      // Restored snapshot is paused — run() should be rejected.
      expect(() => restoredFfi.run('x'), throwsStateError);

      // resume() should be allowed (active state).
      mock.resumeResults.add(
        ProgressResult(
          tag: 0,
          resultJson: _okResultJson(10),
          isError: 0,
        ),
      );
      final progress = await restoredFfi.resume('val');
      expect(progress, isA<MontyComplete>());
      expect((progress as MontyComplete).result.value, 10);
    });

    test('throws StateError when restore fails', () {
      mock.nextRestoreError = 'invalid snapshot';

      expect(
        () => monty.restore(Uint8List.fromList([0xFF])),
        throwsStateError,
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
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
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
    test('frees active handle', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('x', externalFunctions: ['f']);

      await monty.dispose();

      // free from start (if complete) doesn't happen since pending,
      // but dispose frees it.
      expect(mock.freeCalls, isNotEmpty);
    });

    test('double dispose is safe', () async {
      await monty.dispose();
      await monty.dispose(); // should not throw

      // Only freed once (no handle to free in idle state).
      expect(mock.freeCalls, isEmpty);
    });
  });

  // ===========================================================================
  // Edge cases
  // ===========================================================================
  group('edge cases', () {
    test('run with null value in result', () async {
      mock.nextRunResult = RunResult(tag: 0, resultJson: _okResultJson(null));

      final result = await monty.run('None');
      expect(result.value, isNull);
      expect(result.isError, isFalse);
    });

    test('run with string value in result', () async {
      mock.nextRunResult =
          RunResult(tag: 0, resultJson: _okResultJson('"hello"'));

      final result = await monty.run('"hello"');
      expect(result.value, 'hello');
    });

    test('run with error in result JSON', () async {
      mock.nextRunResult = RunResult(
        tag: 0,
        resultJson: _errorResultJson('NameError'),
      );

      final result = await monty.run('x');
      expect(result.isError, isTrue);
      final error = result.error;
      expect(error, isNotNull);
      expect(error?.message, 'NameError');
    });

    test('pending with empty arguments', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'noop',
        argumentsJson: '[]',
      );

      final progress = await monty.start(
        'noop()',
        externalFunctions: ['noop'],
      );

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('pending with null argumentsJson defaults to empty', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'noop',
      );

      final progress = await monty.start(
        'noop()',
        externalFunctions: ['noop'],
      );

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('create error propagates', () async {
      mock.nextCreateError = 'compilation failed';

      expect(() => monty.run('bad'), throwsStateError);
    });

    test('run with null resultJson throws', () async {
      mock.nextRunResult = const RunResult(tag: 0);

      expect(() => monty.run('x'), throwsStateError);
    });

    test('complete with null resultJson throws', () async {
      mock.nextStartResult = const ProgressResult(tag: 0, isError: 0);

      expect(() => monty.start('x'), throwsStateError);
    });

    test('unknown progress tag throws', () async {
      mock.nextStartResult = const ProgressResult(tag: 99);

      expect(() => monty.start('x'), throwsStateError);
    });

    test('error progress with null message uses default', () async {
      mock.nextStartResult = const ProgressResult(tag: 2);

      expect(
        () => monty.start('x'),
        throwsA(
          isA<MontyException>().having(
            (e) => e.message,
            'message',
            'Unknown error',
          ),
        ),
      );
    });

    test('run error result includes excType and traceback', () async {
      const errorJson = '{"value": null, "error": {'
          ' "message": "division by zero",'
          ' "exc_type": "ZeroDivisionError",'
          ' "traceback": [{"filename": "test.py", "start_line": 1,'
          ' "start_column": 1, "end_line": 1, "end_column": 4}]'
          ' }, "usage": $_usageJson}';
      mock.nextRunResult = const RunResult(tag: 0, resultJson: errorJson);

      final result = await monty.run('1/0');
      expect(result.isError, isTrue);
      final error = result.error!;
      expect(error.excType, 'ZeroDivisionError');
      expect(error.traceback, hasLength(1));
      expect(error.traceback.first.filename, 'test.py');
      expect(error.traceback.first.startLine, 1);
    });

    test('run error with null message uses default', () async {
      mock.nextRunResult = const RunResult(tag: 1);

      expect(
        () => monty.run('x'),
        throwsA(
          isA<MontyException>().having(
            (e) => e.message,
            'message',
            'Unknown error',
          ),
        ),
      );
    });

    test('run error tag=1 parses excType and traceback from resultJson',
        () async {
      const errorJson = '{"value": null, "error": {'
          ' "message": "division by zero",'
          ' "exc_type": "ZeroDivisionError",'
          ' "filename": "test.py",'
          ' "line_number": 1,'
          ' "traceback": [{"filename": "test.py", "start_line": 1,'
          ' "start_column": 0, "end_line": 1, "end_column": 3}]'
          ' }, "usage": $_usageJson}';
      mock.nextRunResult =
          const RunResult(tag: 1, resultJson: errorJson, errorMessage: 'err');

      try {
        await monty.run('1/0');
        fail('Expected MontyException');
      } on MontyException catch (e) {
        expect(e.excType, 'ZeroDivisionError');
        expect(e.message, 'division by zero');
        expect(e.filename, 'test.py');
        expect(e.traceback, hasLength(1));
        expect(e.traceback.first.filename, 'test.py');
      }
    });

    test('run error tag=1 falls back to errorMessage when no resultJson',
        () async {
      mock.nextRunResult =
          const RunResult(tag: 1, errorMessage: 'fallback msg');

      expect(
        () => monty.run('x'),
        throwsA(
          isA<MontyException>().having(
            (e) => e.message,
            'message',
            'fallback msg',
          ),
        ),
      );
    });

    test('progress error parses excType from resultJson', () async {
      const errorJson = '{"value": null, "error": {'
          ' "message": "name error",'
          ' "exc_type": "NameError",'
          ' "traceback": [{"filename": "<module>", "start_line": 1,'
          ' "start_column": 0, "end_line": 1, "end_column": 5}]'
          ' }, "usage": $_usageJson}';
      mock.nextStartResult = const ProgressResult(
        tag: 2,
        errorMessage: 'name error',
        resultJson: errorJson,
      );

      try {
        await monty.start('x', externalFunctions: ['f']);
        fail('Expected MontyException');
      } on MontyException catch (e) {
        expect(e.excType, 'NameError');
        expect(e.message, 'name error');
        expect(e.traceback, hasLength(1));
      }
    });

    test('pending with empty kwargs decoded as null', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'ext_fn',
        argumentsJson: '[42]',
        kwargsJson: '{}',
        callId: 0,
        methodCall: false,
      );

      final progress = await monty.start('x', externalFunctions: ['ext_fn']);
      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.kwargs, isNull);
      expect(pending.arguments, [42]);
    });
  });

  // ===========================================================================
  // Async / Futures
  // ===========================================================================
  group('resumeAsFuture()', () {
    test('returns MontyResolveFutures', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '["x"]',
        callId: 0,
      );
      await monty.start('code', externalFunctions: ['fetch']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(tag: 3, futureCallIdsJson: '[0]'),
      );
      final progress = await monty.resumeAsFuture();

      expect(progress, isA<MontyResolveFutures>());
      final futures = progress as MontyResolveFutures;
      expect(futures.pendingCallIds, [0]);
    });

    test('returns MontyPending for another call', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'foo',
        argumentsJson: '[]',
        callId: 0,
      );
      await monty.start('code', externalFunctions: ['foo', 'bar']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(
          tag: 1,
          functionName: 'bar',
          argumentsJson: '[]',
          callId: 1,
        ),
      );
      final progress = await monty.resumeAsFuture();

      expect(progress, isA<MontyPending>());
      expect((progress as MontyPending).functionName, 'bar');
    });

    test('throws StateError when idle', () {
      expect(() => monty.resumeAsFuture(), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resumeAsFuture(), throwsStateError);
    });

    test('calls bindings with correct handle', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('code', externalFunctions: ['f']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(tag: 3, futureCallIdsJson: '[0]'),
      );
      await monty.resumeAsFuture();

      expect(mock.resumeAsFutureCalls, [mock.nextCreateHandle]);
    });
  });

  group('resolveFutures()', () {
    test('returns MontyComplete after resolving', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
        callId: 0,
      );
      await monty.start('code', externalFunctions: ['f']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(tag: 3, futureCallIdsJson: '[0]'),
      );
      await monty.resumeAsFuture();

      mock.resolveFuturesResults.add(
        ProgressResult(tag: 0, resultJson: _okResultJson('"done"'), isError: 0),
      );
      final progress = await monty.resolveFutures({0: 'done'});

      expect(progress, isA<MontyComplete>());
      expect((progress as MontyComplete).result.value, 'done');
    });

    test('passes correct JSON to bindings', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('code', externalFunctions: ['f']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(tag: 3, futureCallIdsJson: '[0,1]'),
      );
      await monty.resumeAsFuture();

      await monty.resolveFutures({0: 'a', 1: 42});

      expect(mock.resolveFuturesCalls, hasLength(1));
      final call = mock.resolveFuturesCalls.first;
      expect(call.resultsJson, '{"0":"a","1":42}');
      expect(call.errorsJson, '{}');
    });

    test('throws StateError when idle', () {
      expect(() => monty.resolveFutures({0: 'x'}), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resolveFutures({0: 'x'}), throwsStateError);
    });
  });

  group('resolveFuturesWithErrors()', () {
    test('passes results and errors to bindings', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'f',
        argumentsJson: '[]',
      );
      await monty.start('code', externalFunctions: ['f']);

      mock.resumeAsFutureResults.add(
        const ProgressResult(tag: 3, futureCallIdsJson: '[0,1]'),
      );
      await monty.resumeAsFuture();

      await monty.resolveFuturesWithErrors({0: 'ok'}, {1: 'timeout'});

      expect(mock.resolveFuturesCalls, hasLength(1));
      final call = mock.resolveFuturesCalls.first;
      expect(call.resultsJson, '{"0":"ok"}');
      expect(call.errorsJson, '{"1":"timeout"}');
    });

    test('throws StateError when idle', () {
      expect(
        () => monty.resolveFuturesWithErrors({}, {}),
        throwsStateError,
      );
    });
  });
}
