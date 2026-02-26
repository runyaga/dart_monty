import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/src/monty_wasm.dart';
import 'package:dart_monty_wasm/src/wasm_bindings.dart';
import 'package:test/test.dart';

import 'mock_wasm_bindings.dart';

void main() {
  late MockWasmBindings mock;
  late MontyWasm monty;

  setUp(() {
    mock = MockWasmBindings();
    monty = MontyWasm(bindings: mock);
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
      mock.nextRunResult = const WasmRunResult(ok: true, value: 4);

      final result = await monty.run('2 + 2');

      expect(result.value, 4);
      expect(result.isError, isFalse);
      expect(result.usage.memoryBytesUsed, 0);
      expect(result.usage.timeElapsedMs, greaterThanOrEqualTo(0));
      expect(result.usage.stackDepthUsed, 0);
      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.code, '2 + 2');
    });

    test('auto-initializes on first call', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      expect(mock.initCalls, 1);
    });

    test('does not re-initialize after first call', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      await monty.run('2');
      expect(mock.initCalls, 1);
    });

    test('throws MontyException on error result', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'SyntaxError: invalid syntax',
        errorType: 'SyntaxError',
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
      mock.nextRunResult = const WasmRunResult(ok: true, value: 42);

      await monty.run(
        'x',
        limits: const MontyLimits(
          memoryBytes: 1024,
          timeoutMs: 500,
          stackDepth: 10,
        ),
      );

      expect(mock.runCalls, hasLength(1));
      final limitsJson = mock.runCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson ?? '') as Map<String, dynamic>;
      expect(decoded['memory_bytes'], 1024);
      expect(decoded['timeout_ms'], 500);
      expect(decoded['stack_depth'], 10);
    });

    test('passes null limitsJson when no limits', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      expect(mock.runCalls.first.limitsJson, isNull);
    });

    test('passes null limitsJson when all limits are null', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1', limits: const MontyLimits());
      expect(mock.runCalls.first.limitsJson, isNull);
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => monty.run('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('allows null inputs', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      // Verifying null inputs are accepted without error.
      // ignore: avoid_redundant_argument_values
      final result = await monty.run('1', inputs: null);
      expect(result.value, 1);
    });

    test('allows empty inputs', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      final result = await monty.run('1', inputs: {});
      expect(result.value, 1);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.run('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
      );
      await monty.start('x', externalFunctions: ['fetch']);

      expect(() => monty.run('y'), throwsStateError);
    });

    test('returns null value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true);

      final result = await monty.run('None');
      expect(result.value, isNull);
      expect(result.isError, isFalse);
    });

    test('returns string value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 'hello');

      final result = await monty.run('"hello"');
      expect(result.value, 'hello');
    });

    test('error with null message uses default', () async {
      mock.nextRunResult = const WasmRunResult(ok: false);

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
  });

  // ===========================================================================
  // start()
  // ===========================================================================
  group('start()', () {
    test('returns MontyComplete when code completes immediately', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
        value: 42,
      );

      final progress = await monty.start('42');

      expect(progress, isA<MontyComplete>());
      final complete = progress as MontyComplete;
      expect(complete.result.value, 42);
    });

    test('returns MontyPending for external function call', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: ['https://example.com'],
      );

      final progress = await monty.start(
        'fetch("https://example.com")',
        externalFunctions: ['fetch'],
      );

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'fetch');
      expect(pending.arguments, ['https://example.com']);
      expect(mock.startCalls.first.extFnsJson, '["fetch"]');
    });

    test('passes multiple external functions as JSON array', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'a',
        arguments: [],
      );

      await monty.start(
        'a()',
        externalFunctions: ['a', 'b', 'c'],
      );

      expect(mock.startCalls.first.extFnsJson, '["a","b","c"]');
    });

    test('passes null extFnsJson when empty list', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await monty.start('x', externalFunctions: []);

      expect(mock.startCalls.first.extFnsJson, isNull);
    });

    test('passes null extFnsJson when null', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await monty.start('x');

      expect(mock.startCalls.first.extFnsJson, isNull);
    });

    test('throws MontyException on error progress', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'compilation failed',
        errorType: 'CompileError',
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
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
      );
      await monty.start('x', externalFunctions: ['f']);

      expect(() => monty.start('y'), throwsStateError);
    });

    test('applies limits before starting', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await monty.start(
        'x',
        limits: const MontyLimits(memoryBytes: 512),
      );

      final limitsJson = mock.startCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson ?? '') as Map<String, dynamic>;
      expect(decoded['memory_bytes'], 512);
    });

    test('error with null message uses default', () async {
      mock.nextStartResult = const WasmProgressResult(ok: false);

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

    test('unknown state throws StateError', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'unknown',
      );

      expect(() => monty.start('x'), throwsStateError);
    });
  });

  // ===========================================================================
  // resume()
  // ===========================================================================
  group('resume()', () {
    setUp(() async {
      // Start in active state.
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete when execution finishes', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'hello',
        ),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeCalls, hasLength(1));
      expect(mock.resumeCalls.first, '"response"');
    });

    test('returns MontyPending for another external call', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'save',
          arguments: ['data'],
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
        const WasmProgressResult(
          ok: false,
          error: 'runtime error',
          errorType: 'RuntimeError',
        ),
      );

      expect(
        () => monty.resume(null),
        throwsA(isA<MontyException>()),
      );
    });

    test('throws StateError when idle', () async {
      // Complete the execution first to go back to idle.
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
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
        const WasmProgressResult(
          ok: true,
          state: 'complete',
        ),
      );

      await monty.resume({
        'key': [1, 2, 3],
      });

      expect(mock.resumeCalls.first, '{"key":[1,2,3]}');
    });
  });

  // ===========================================================================
  // resumeWithError()
  // ===========================================================================
  group('resumeWithError()', () {
    setUp(() async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
      );
      await monty.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete after error injection', () async {
      mock.resumeWithErrorResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
        ),
      );

      final progress = await monty.resumeWithError('network failure');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeWithErrorCalls, hasLength(1));
      expect(mock.resumeWithErrorCalls.first, 'network failure');
    });

    test('returns MontyPending for continuation', () async {
      mock.resumeWithErrorResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'retry',
          arguments: [],
        ),
      );

      final progress = await monty.resumeWithError('timeout');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'retry');
    });

    test('throws StateError when idle', () {
      final freshMonty = MontyWasm(bindings: mock);
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
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
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
      final freshMonty = MontyWasm(bindings: mock);
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
    test('returns new MontyWasm instance', () async {
      final data = Uint8List.fromList([1, 2, 3]);

      final restored = await monty.restore(data);

      expect(restored, isA<MontyWasm>());
      expect(mock.restoreCalls, hasLength(1));
      expect(mock.restoreCalls.first, data);
    });

    test('restored instance is in active state', () async {
      final restored = await monty.restore(Uint8List.fromList([1, 2, 3]));
      final restoredWasm = restored as MontyWasm;

      // Restored snapshot is paused — run() should be rejected.
      expect(() => restoredWasm.run('x'), throwsStateError);

      // resume() should be allowed (active state).
      mock.resumeResults.add(
        const WasmProgressResult(ok: true, state: 'complete', value: 10),
      );
      final progress = await restoredWasm.resume('val');
      expect(progress, isA<MontyComplete>());
      expect((progress as MontyComplete).result.value, 10);
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
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
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
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1'); // triggers auto-init
      await monty.dispose();
      expect(mock.disposeCalls, 1);
    });

    test('does not call bindings dispose when not initialized', () async {
      await monty.dispose();
      expect(mock.disposeCalls, 0);
    });

    test('double dispose is safe', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1'); // triggers auto-init
      await monty.dispose();
      await monty.dispose(); // should not throw

      expect(mock.disposeCalls, 1);
    });
  });

  // ===========================================================================
  // Edge cases
  // ===========================================================================
  group('edge cases', () {
    test('pending with null arguments defaults to empty', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'noop',
      );

      final progress = await monty.start(
        'noop()',
        externalFunctions: ['noop'],
      );

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('pending with empty arguments', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'noop',
        arguments: [],
      );

      final progress = await monty.start(
        'noop()',
        externalFunctions: ['noop'],
      );

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('pending with null functionName defaults to empty', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
      );

      final progress = await monty.start(
        'x()',
        externalFunctions: ['x'],
      );

      final pending = progress as MontyPending;
      expect(pending.functionName, '');
    });

    test('complete with null value', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      final progress = await monty.start('None');

      final complete = progress as MontyComplete;
      expect(complete.result.value, isNull);
    });

    test('resource usage has Dart-side wall-clock timing', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      final result = await monty.run('1');

      expect(result.usage.memoryBytesUsed, 0);
      expect(result.usage.timeElapsedMs, greaterThanOrEqualTo(0));
      expect(result.usage.stackDepthUsed, 0);
    });

    test('partial limits encode only present fields', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      await monty.run(
        '1',
        limits: const MontyLimits(timeoutMs: 300),
      );

      final limitsJson = mock.runCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson ?? '') as Map<String, dynamic>;
      expect(decoded, {'timeout_ms': 300});
      expect(decoded.containsKey('memory_bytes'), isFalse);
      expect(decoded.containsKey('stack_depth'), isFalse);
    });
  });

  // ===========================================================================
  // kwargs, callId, methodCall, scriptName, excType, traceback
  // ===========================================================================
  group('data model fidelity', () {
    test('start() returns MontyPending with kwargs', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: ['url'],
        kwargs: {'timeout': 30, 'retries': 3},
      );

      final progress = await monty.start(
        'fetch("url", timeout=30, retries=3)',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.kwargs, {'timeout': 30, 'retries': 3});
    });

    test('start() returns MontyPending with callId and methodCall', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
        callId: 42,
        methodCall: true,
      );

      final progress = await monty.start(
        'x',
        externalFunctions: ['fetch'],
      );

      final pending = progress as MontyPending;
      expect(pending.callId, 42);
      expect(pending.methodCall, isTrue);
    });

    test('start() defaults kwargs/callId/methodCall when absent', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
      );

      final progress = await monty.start(
        'x',
        externalFunctions: ['f'],
      );

      final pending = progress as MontyPending;
      expect(pending.kwargs, isNull);
      expect(pending.callId, 0);
      expect(pending.methodCall, isFalse);
    });

    test('run() passes scriptName to bindings', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      await monty.run('1', scriptName: 'my_script.py');

      expect(mock.runCalls.first.scriptName, 'my_script.py');
    });

    test('start() passes scriptName to bindings', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await monty.start('x', scriptName: 'pipeline.py');

      expect(mock.startCalls.first.scriptName, 'pipeline.py');
    });

    test('run() error includes excType and traceback', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'division by zero',
        errorType: 'ZeroDivisionError',
        excType: 'ZeroDivisionError',
        traceback: [
          {
            'filename': '<input>',
            'start_line': 1,
            'start_column': 0,
            'end_line': 1,
            'end_column': 3,
            'frame_name': '<module>',
            'preview_line': '1/0',
          },
        ],
      );

      try {
        await monty.run('1/0');
        fail('Expected MontyException');
      } on MontyException catch (e) {
        expect(e.excType, 'ZeroDivisionError');
        final traceback = e.traceback;
        expect(traceback, hasLength(1));
        final frame = traceback.first;
        expect(frame.filename, '<input>');
        expect(frame.startLine, 1);
        expect(frame.frameName, '<module>');
        expect(frame.previewLine, '1/0');
      }
    });

    test('start() error includes excType and traceback', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'name error',
        errorType: 'NameError',
        excType: 'NameError',
        traceback: [
          {
            'filename': 'test.py',
            'start_line': 5,
            'start_column': 2,
          },
        ],
      );

      try {
        await monty.start('x');
        fail('Expected MontyException');
      } on MontyException catch (e) {
        expect(e.excType, 'NameError');
        final startTraceback = e.traceback;
        expect(startTraceback, hasLength(1));
        expect(startTraceback.first.filename, 'test.py');
        expect(startTraceback.first.startLine, 5);
      }
    });

    test('error with null traceback defaults to empty list', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'some error',
        excType: 'ValueError',
      );

      try {
        await monty.run('x');
        fail('Expected MontyException');
      } on MontyException catch (e) {
        expect(e.excType, 'ValueError');
        expect(e.traceback, isEmpty);
      }
    });
  });

  // ===========================================================================
  // Capability interfaces
  // ===========================================================================
  group('capability interfaces', () {
    test('is MontySnapshotCapable', () {
      expect(monty, isA<MontySnapshotCapable>());
    });

    test('is not MontyFutureCapable', () {
      expect(monty, isNot(isA<MontyFutureCapable>()));
    });
  });

  // ===========================================================================
  // Async/Futures (M13) — forward-compat state handling
  // ===========================================================================
  group('async/futures (M13)', () {
    test('start() returns MontyResolveFutures for resolve_futures state',
        () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0, 1, 2],
      );

      final progress = await monty.start(
        'await asyncio.gather(a(), b(), c())',
        externalFunctions: ['a', 'b', 'c'],
      );

      expect(progress, isA<MontyResolveFutures>());
      final rf = progress as MontyResolveFutures;
      expect(rf.pendingCallIds, [0, 1, 2]);
    });

    test('resolve_futures state defaults to empty pendingCallIds', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
      );

      final progress = await monty.start('x');

      expect(progress, isA<MontyResolveFutures>());
      final rf = progress as MontyResolveFutures;
      expect(rf.pendingCallIds, isEmpty);
    });

    test('resolve_futures sets state to active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0],
      );

      await monty.start('x', externalFunctions: ['a']);

      // Active state — cannot run() or start().
      expect(() => monty.run('y'), throwsStateError);
      expect(() => monty.start('y'), throwsStateError);
    });
  });
}
