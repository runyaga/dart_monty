import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

import 'mock_native_bindings.dart';

void main() {
  late MockNativeBindings mock;
  late FfiCoreBindings bindings;

  setUp(() {
    mock = MockNativeBindings();
    bindings = FfiCoreBindings(bindings: mock);
  });

  group('init()', () {
    test('returns true', () async {
      expect(await bindings.init(), isTrue);
    });
  });

  group('run()', () {
    test('success translates to CoreRunResult(ok: true)', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": 42, "usage": {"memory_bytes_used": 100, '
            '"time_elapsed_ms": 5, "stack_depth_used": 3}}',
      );

      final result = await bindings.run('2 + 2');

      expect(result.ok, isTrue);
      expect(result.value, 42);
      expect(
        result.usage,
        const MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 5,
          stackDepthUsed: 3,
        ),
      );
      expect(result.printOutput, isNull);
      expect(result.error, isNull);
      expect(mock.createCalls, hasLength(1));
      expect(mock.createCalls.first.code, '2 + 2');
      expect(mock.freeCalls, hasLength(1));
    });

    test('success with print_output preserves it', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}, '
            r'"print_output": "hello\n"}',
      );

      final result = await bindings.run('print("hello")');

      expect(result.printOutput, 'hello\n');
    });

    test('success with embedded error preserves error fields', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}, '
            '"error": {"message": "NameError", "exc_type": "NameError"}}',
      );

      final result = await bindings.run('code');

      expect(result.ok, isTrue);
      expect(result.error, 'NameError');
      expect(result.excType, 'NameError');
    });

    test('error with result JSON extracts error details', () async {
      mock.nextRunResult = const RunResult(
        tag: 1,
        resultJson: '{"error": {"message": "division by zero", '
            '"exc_type": "ZeroDivisionError", '
            '"traceback": [{"filename": "<test>", "start_line": 1}]}}',
      );

      final result = await bindings.run('1/0');

      expect(result.ok, isFalse);
      expect(result.error, 'division by zero');
      expect(result.excType, 'ZeroDivisionError');
      expect(result.traceback, hasLength(1));
    });

    test('error falls back to errorMessage', () async {
      mock.nextRunResult = const RunResult(
        tag: 1,
        errorMessage: 'C API error',
      );

      final result = await bindings.run('bad');

      expect(result.ok, isFalse);
      expect(result.error, 'C API error');
    });

    test('error with null everything uses Unknown error', () async {
      mock.nextRunResult = const RunResult(tag: 1);

      final result = await bindings.run('bad');

      expect(result.ok, isFalse);
      expect(result.error, 'Unknown error');
    });

    test('passes scriptName to create()', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.run('code', scriptName: 'math.py');

      expect(mock.createCalls.first.scriptName, 'math.py');
    });

    test('applies limits from JSON', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.run(
        'code',
        limitsJson: '{"memory_bytes": 1024, "timeout_ms": 5000, '
            '"stack_depth": 100}',
      );

      expect(mock.setMemoryLimitCalls, hasLength(1));
      expect(mock.setMemoryLimitCalls.first.bytes, 1024);
      expect(mock.setTimeLimitMsCalls, hasLength(1));
      expect(mock.setTimeLimitMsCalls.first.ms, 5000);
      expect(mock.setStackLimitCalls, hasLength(1));
      expect(mock.setStackLimitCalls.first.depth, 100);
    });

    test('null limits skips limit calls', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.run('code');

      expect(mock.setMemoryLimitCalls, isEmpty);
      expect(mock.setTimeLimitMsCalls, isEmpty);
      expect(mock.setStackLimitCalls, isEmpty);
    });

    test('frees handle even on error', () async {
      mock.nextRunResult = const RunResult(
        tag: 1,
        errorMessage: 'error',
      );

      await bindings.run('bad');

      expect(mock.freeCalls, hasLength(1));
    });

    test('null result JSON on tag 0 throws StateError', () async {
      mock.nextRunResult = const RunResult(tag: 0);

      await expectLater(
        () => bindings.run('code'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('start()', () {
    test('complete translates to CoreProgressResult', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 0,
        resultJson: '{"value": 99, "usage": {"memory_bytes_used": 50, '
            '"time_elapsed_ms": 2, "stack_depth_used": 1}}',
      );

      final result = await bindings.start('code');

      expect(result.state, 'complete');
      expect(result.value, 99);
      expect(
        result.usage,
        const MontyResourceUsage(
          memoryBytesUsed: 50,
          timeElapsedMs: 2,
          stackDepthUsed: 1,
        ),
      );
      expect(mock.freeCalls, hasLength(1));
    });

    test('complete with embedded error preserves error', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}, '
            '"error": {"message": "caught", "exc_type": "RuntimeError"}}',
      );

      final result = await bindings.start('code');

      expect(result.state, 'complete');
      expect(result.error, 'caught');
      expect(result.excType, 'RuntimeError');
    });

    test('pending translates with all fields', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'get_data',
        argumentsJson: '[1, "two"]',
        kwargsJson: '{"timeout": 30}',
        callId: 7,
        methodCall: true,
      );

      final result = await bindings.start(
        'code',
        extFnsJson: '["get_data"]',
      );

      expect(result.state, 'pending');
      expect(result.functionName, 'get_data');
      expect(result.arguments, [1, 'two']);
      expect(result.kwargs, {'timeout': 30});
      expect(result.callId, 7);
      expect(result.methodCall, isTrue);
      expect(mock.createCalls.first.externalFunctions, 'get_data');
    });

    test('pending with empty kwargs maps to null', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
        argumentsJson: '[]',
        kwargsJson: '{}',
      );

      final result = await bindings.start(
        'code',
        extFnsJson: '["fn"]',
      );

      expect(result.kwargs, isNull);
    });

    test('pending with null args defaults to empty list', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );

      final result = await bindings.start(
        'code',
        extFnsJson: '["fn"]',
      );

      expect(result.arguments, isEmpty);
    });

    test('error with result JSON extracts details', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 2,
        resultJson: '{"error": {"message": "not defined", '
            '"exc_type": "NameError"}}',
      );

      final result = await bindings.start('code');

      expect(result.state, 'error');
      expect(result.error, 'not defined');
      expect(result.excType, 'NameError');
    });

    test('error falls back to errorMessage', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 2,
        errorMessage: 'fallback error',
      );

      final result = await bindings.start('code');

      expect(result.state, 'error');
      expect(result.error, 'fallback error');
    });

    test('resolve_futures translates pending call IDs', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 3,
        futureCallIdsJson: '[1, 2, 3]',
      );

      final result = await bindings.start(
        'code',
        extFnsJson: '["fn"]',
      );

      expect(result.state, 'resolve_futures');
      expect(result.pendingCallIds, [1, 2, 3]);
    });

    test('unknown tag throws StateError', () async {
      mock.nextStartResult = const ProgressResult(tag: 99);

      await expectLater(
        () => bindings.start('code'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('99'),
          ),
        ),
      );
    });

    test('external functions joined as comma-separated', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.start(
        'code',
        extFnsJson: '["fn_a", "fn_b"]',
      );

      expect(mock.createCalls.first.externalFunctions, 'fn_a,fn_b');
    });

    test('null extFnsJson passes null to create', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 0,
        resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.start('code');

      expect(mock.createCalls.first.externalFunctions, isNull);
    });
  });

  group('resume()', () {
    test('delegates valueJson and translates result', () async {
      // Enter active state via start → pending.
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      // Now resume.
      mock.resumeResults.add(
        const ProgressResult(
          tag: 0,
          resultJson: '{"value": "done", "usage": {"memory_bytes_used": 0, '
              '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
        ),
      );

      final result = await bindings.resume(json.encode(42));

      expect(mock.resumeCalls, hasLength(1));
      expect(mock.resumeCalls.first.valueJson, json.encode(42));
      expect(result.state, 'complete');
      expect(result.value, 'done');
    });

    test('throws StateError when no handle', () async {
      await expectLater(
        () => bindings.resume('"val"'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('resume'),
          ),
        ),
      );
    });
  });

  group('resumeWithError()', () {
    test('delegates errorMessage and translates result', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      mock.resumeWithErrorResults.add(
        const ProgressResult(
          tag: 0,
          resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
              '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
        ),
      );

      final result = await bindings.resumeWithError('not found');

      expect(mock.resumeWithErrorCalls, hasLength(1));
      expect(mock.resumeWithErrorCalls.first.errorMessage, 'not found');
      expect(result.state, 'complete');
    });

    test('throws StateError when no handle', () async {
      await expectLater(
        () => bindings.resumeWithError('err'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('resumeAsFuture()', () {
    test('delegates and translates result', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      mock.resumeAsFutureResults.add(
        const ProgressResult(
          tag: 3,
          futureCallIdsJson: '[0]',
        ),
      );

      final result = await bindings.resumeAsFuture();

      expect(mock.resumeAsFutureCalls, hasLength(1));
      expect(result.state, 'resolve_futures');
      expect(result.pendingCallIds, [0]);
    });

    test('throws StateError when no handle', () async {
      await expectLater(
        () => bindings.resumeAsFuture(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('resolveFutures()', () {
    test('delegates and translates result', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 3,
        futureCallIdsJson: '[1]',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      mock.resolveFuturesResults.add(
        const ProgressResult(
          tag: 0,
          resultJson: '{"value": "resolved", "usage": '
              '{"memory_bytes_used": 0, "time_elapsed_ms": 0, '
              '"stack_depth_used": 0}}',
        ),
      );

      final result = await bindings.resolveFutures(
        '{"1": "value"}',
        '{}',
      );

      expect(mock.resolveFuturesCalls, hasLength(1));
      expect(result.state, 'complete');
      expect(result.value, 'resolved');
    });

    test('throws StateError when no handle', () async {
      await expectLater(
        () => bindings.resolveFutures('{}', '{}'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('snapshot()', () {
    test('delegates to bindings', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      mock.nextSnapshotData = Uint8List.fromList([10, 20, 30]);
      final data = await bindings.snapshot();

      expect(data, Uint8List.fromList([10, 20, 30]));
      expect(mock.snapshotCalls, hasLength(1));
    });

    test('throws StateError when no handle', () async {
      await expectLater(
        () => bindings.snapshot(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('restoreSnapshot()', () {
    test('stores new handle from restore', () async {
      mock.nextRestoreHandle = 99;
      final data = Uint8List.fromList([1, 2, 3]);

      await bindings.restoreSnapshot(data);

      expect(mock.restoreCalls, hasLength(1));
      // Verify handle is stored by calling snapshot (which requires handle).
      mock.nextSnapshotData = Uint8List.fromList([4, 5, 6]);
      final snapshot = await bindings.snapshot();
      expect(snapshot, Uint8List.fromList([4, 5, 6]));
    });
  });

  group('dispose()', () {
    test('frees active handle', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      await bindings.dispose();

      expect(mock.freeCalls, hasLength(1));
    });

    test('no-op when no handle', () async {
      await bindings.dispose();

      expect(mock.freeCalls, isEmpty);
    });

    test('second dispose is no-op', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      await bindings.dispose();
      mock.freeCalls.clear();
      await bindings.dispose();

      expect(mock.freeCalls, isEmpty);
    });
  });

  group('handle lifecycle', () {
    test('run creates and frees handle each call', () async {
      mock.nextRunResult = const RunResult(
        tag: 0,
        resultJson: '{"value": 1, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await bindings.run('first');
      await bindings.run('second');

      expect(mock.createCalls, hasLength(2));
      expect(mock.freeCalls, hasLength(2));
    });

    test('start stores handle on pending, frees on complete', () async {
      mock.nextStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
      );
      await bindings.start('code', extFnsJson: '["fn"]');

      // Handle stored, not freed yet.
      expect(mock.freeCalls, isEmpty);

      // Resume → complete → handle freed.
      mock.resumeResults.add(
        const ProgressResult(
          tag: 0,
          resultJson: '{"value": null, "usage": {"memory_bytes_used": 0, '
              '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
        ),
      );
      await bindings.resume('"done"');

      expect(mock.freeCalls, hasLength(1));
    });
  });
}
