@Tags(['browser'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty/src/wasm/monty_wasm.dart';
import 'package:dart_monty/src/wasm/wasm_bindings.dart';
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

      expect(result.value, const MontyInt(4));
      expect(result.isError, isFalse);
      expect(result.usage.memoryBytesUsed, 0);
      expect(result.usage.timeElapsedMs, greaterThanOrEqualTo(0));
      expect(result.usage.stackDepthUsed, 0);
      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.code, '2 + 2');
    });

    test('run preserves printOutput', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: true,
        value: 42,
        printOutput: 'hello\n',
      );

      final result = await monty.run('print("hello")');

      expect(result.printOutput, 'hello\n');
    });

    test('auto-initializes on first call', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      expect(mock.createSessionCalls, 1);
    });

    test('does not re-initialize after first call', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      await monty.run('2');
      expect(mock.createSessionCalls, 1);
    });

    test('throws MontyScriptError on error result', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'SyntaxError: invalid syntax',
        errorType: 'SyntaxError',
      );

      expect(
        () => monty.run('def'),
        throwsA(
          isA<MontyScriptError>().having(
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

    test('applies default limits when no limits provided', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1');
      final limitsJson = mock.runCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson!) as Map<String, dynamic>;
      expect(decoded['memory_bytes'], BaseMontyPlatform.defaultMemoryBytes);
      expect(decoded['stack_depth'], BaseMontyPlatform.defaultStackDepth);
      expect(decoded.containsKey('timeout_ms'), isFalse);
    });

    test('applies default limits when all limits are null', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1', limits: const MontyLimits());
      final limitsJson = mock.runCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson!) as Map<String, dynamic>;
      expect(decoded['memory_bytes'], BaseMontyPlatform.defaultMemoryBytes);
      expect(decoded['stack_depth'], BaseMontyPlatform.defaultStackDepth);
      expect(decoded.containsKey('timeout_ms'), isFalse);
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
      expect(result.value, const MontyNull());
      expect(result.isError, isFalse);
    });

    test('returns string value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 'hello');

      final result = await monty.run('"hello"');
      expect(result.value, const MontyString('hello'));
    });

    test('error with null message uses default', () async {
      mock.nextRunResult = const WasmRunResult(ok: false);

      expect(
        () => monty.run('x'),
        throwsA(
          isA<MontyScriptError>().having(
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
      expect(complete.result.value, const MontyInt(42));
    });

    test('start complete preserves printOutput', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
        value: 42,
        printOutput: 'hello\n',
      );

      final progress = await monty.start('print("hello")');

      final complete = progress as MontyComplete;
      expect(complete.result.printOutput, 'hello\n');
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
      expect(pending.arguments, [const MontyString('https://example.com')]);
      expect(mock.startCalls.first.extFnsJson, '["fetch"]');
    });

    test('passes multiple external functions as JSON array', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'a',
        arguments: [],
      );

      await monty.start('a()', externalFunctions: ['a', 'b', 'c']);

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

    test('throws MontyScriptError on error progress', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'compilation failed',
        errorType: 'CompileError',
      );

      expect(
        () => monty.start('bad code'),
        throwsA(
          isA<MontyScriptError>().having(
            (e) => e.message,
            'message',
            'compilation failed',
          ),
        ),
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

      await monty.start('x', limits: const MontyLimits(memoryBytes: 512));

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
          isA<MontyScriptError>().having(
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
        const WasmProgressResult(ok: true, state: 'complete', value: 'hello'),
      );

      final progress = await monty.resume('response');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeCalls, hasLength(1));
      expect(mock.resumeCalls.first.valueJson, '"response"');
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
      expect(pending.arguments, [const MontyString('data')]);
    });

    test('throws MontyException on error', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'runtime error',
          errorType: 'RuntimeError',
        ),
      );

      expect(() => monty.resume(null), throwsA(isA<MontyScriptError>()));
    });

    test('throws StateError when idle', () async {
      // Complete the execution first to go back to idle.
      mock.resumeResults.add(
        const WasmProgressResult(ok: true, state: 'complete'),
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
        const WasmProgressResult(ok: true, state: 'complete'),
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
        const WasmProgressResult(ok: true, state: 'complete'),
      );

      final progress = await monty.resumeWithError('network failure');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeWithErrorCalls, hasLength(1));
      expect(mock.resumeWithErrorCalls.first.errorMessage, 'network failure');
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
      expect(() => freshMonty.resumeWithError('err'), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await monty.dispose();
      expect(() => monty.resumeWithError('err'), throwsStateError);
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
      expect(mock.restoreCalls.first.data, data);
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
      expect((progress as MontyComplete).result.value, const MontyInt(10));
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
      expect(() => monty.restore(Uint8List.fromList([1])), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
      );
      await monty.start('x', externalFunctions: ['f']);

      expect(() => monty.restore(Uint8List.fromList([1])), throwsStateError);
    });
  });

  // ===========================================================================
  // dispose()
  // ===========================================================================
  group('dispose()', () {
    test('calls bindings disposeSession when initialized', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1'); // triggers auto-init via createSession
      await monty.dispose();
      expect(mock.disposeSessionCalls.length, 1);
    });

    test('does not call bindings dispose when not initialized', () async {
      await monty.dispose();
      expect(mock.disposeSessionCalls.length, 0);
    });

    test('double dispose is safe', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      await monty.run('1'); // triggers auto-init via createSession
      await monty.dispose();
      await monty.dispose(); // should not throw

      expect(mock.disposeSessionCalls.length, 1);
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

      final progress = await monty.start('noop()', externalFunctions: ['noop']);

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

      final progress = await monty.start('noop()', externalFunctions: ['noop']);

      final pending = progress as MontyPending;
      expect(pending.arguments, isEmpty);
    });

    test('pending with null functionName defaults to empty', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
      );

      final progress = await monty.start('x()', externalFunctions: ['x']);

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
      expect(complete.result.value, const MontyNull());
    });

    test('resource usage has Dart-side wall-clock timing', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      final result = await monty.run('1');

      expect(result.usage.memoryBytesUsed, 0);
      expect(result.usage.timeElapsedMs, greaterThanOrEqualTo(0));
      expect(result.usage.stackDepthUsed, 0);
    });

    test('partial limits merges with defaults', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      await monty.run('1', limits: const MontyLimits(timeoutMs: 300));

      final limitsJson = mock.runCalls.first.limitsJson;
      expect(limitsJson, isNotNull);
      final decoded = json.decode(limitsJson!) as Map<String, dynamic>;
      // Caller timeout + defaults for memory and stack.
      expect(decoded['timeout_ms'], 300);
      expect(decoded['memory_bytes'], BaseMontyPlatform.defaultMemoryBytes);
      expect(decoded['stack_depth'], BaseMontyPlatform.defaultStackDepth);
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
      expect(pending.kwargs, {
        'timeout': const MontyInt(30),
        'retries': const MontyInt(3),
      });
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

      final progress = await monty.start('x', externalFunctions: ['fetch']);

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

      final progress = await monty.start('x', externalFunctions: ['f']);

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
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.excType, 'ZeroDivisionError');
        final traceback = e.exception!.traceback;
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
          {'filename': 'test.py', 'start_line': 5, 'start_column': 2},
        ],
      );

      try {
        await monty.start('x');
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.excType, 'NameError');
        final startTraceback = e.exception!.traceback;
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
        fail('Expected MontyScriptError');
      } on MontyScriptError catch (e) {
        expect(e.excType, 'ValueError');
        expect(e.exception!.traceback, isEmpty);
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

    test('is MontyFutureCapable', () {
      expect(monty, isA<MontyFutureCapable>());
    });
  });

  // ===========================================================================
  // MontyFutureCapable — resumeAsFuture / resolveFutures
  // ===========================================================================
  group('MontyFutureCapable', () {
    test(
      'resumeAsFuture delegates to coreBindings and returns progress',
      () async {
        // Put monty into active state via start().
        mock.nextStartResult = const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'fetch',
        );
        await monty.start('await fetch()', externalFunctions: ['fetch']);

        mock.nextResumeAsFutureResult = const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0],
        );

        final progress = await monty.resumeAsFuture();

        expect(progress, isA<MontyResolveFutures>());
        expect((progress as MontyResolveFutures).pendingCallIds, [0]);
        expect(mock.resumeAsFutureCalls, 1);
      },
    );

    test(
      'resolveFutures delegates results and errors to coreBindings',
      () async {
        // Put monty into active state via start().
        mock.nextStartResult = const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0, 1],
        );
        await monty.start(
          'await a(); await b()',
          externalFunctions: ['a', 'b'],
        );

        mock.nextResolveFuturesResult = const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 42,
        );

        final progress = await monty.resolveFutures(
          {0: 'hello', 1: 'world'},
          errors: {2: 'boom'},
        );

        expect(progress, isA<MontyComplete>());
        expect(mock.resolveFuturesCalls, hasLength(1));
        final call = mock.resolveFuturesCalls.first;
        expect(call.resultsJson, contains('"0"'));
        expect(call.resultsJson, contains('hello'));
        expect(call.errorsJson, contains('"2"'));
        expect(call.errorsJson, contains('boom'));
      },
    );

    test('resolveFutures defaults errors to empty JSON object', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0],
      );
      await monty.start('await a()', externalFunctions: ['a']);

      mock.nextResolveFuturesResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
        value: 99,
      );

      await monty.resolveFutures({0: 42});

      expect(mock.resolveFuturesCalls.first.errorsJson, '{}');
    });

    test('resumeAsFuture throws when disposed', () async {
      await monty.dispose();

      expect(() => monty.resumeAsFuture(), throwsStateError);
    });

    test('resolveFutures throws when disposed', () async {
      await monty.dispose();

      expect(() => monty.resolveFutures({0: 1}), throwsStateError);
    });

    test('resumeAsFuture throws when idle', () {
      // Monty starts idle — not active.
      expect(() => monty.resumeAsFuture(), throwsStateError);
    });

    test('resolveFutures throws when idle', () {
      expect(() => monty.resolveFutures({0: 1}), throwsStateError);
    });
  });

  // ===========================================================================
  // OsCall — OS/filesystem operations
  // ===========================================================================
  group('os_call', () {
    test('start() returns MontyOsCall for os_call state', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'os_call',
        functionName: 'Path.exists',
        arguments: ['/tmp/test.txt'],
        kwargs: {'follow_symlinks': true},
        callId: 42,
      );

      final progress = await monty.start('from pathlib import Path');

      expect(progress, isA<MontyOsCall>());
      final oc = progress as MontyOsCall;
      expect(oc.operationName, 'Path.exists');
      expect(oc.arguments, [const MontyString('/tmp/test.txt')]);
      expect(oc.kwargs, {'follow_symlinks': const MontyBool(true)});
      expect(oc.callId, 42);
    });

    test('os_call defaults to empty arguments', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'os_call',
        functionName: 'os.getenv',
      );

      final progress = await monty.start('import os');

      expect(progress, isA<MontyOsCall>());
      final oc = progress as MontyOsCall;
      expect(oc.operationName, 'os.getenv');
      expect(oc.arguments, isEmpty);
    });

    test('os_call sets state to active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'os_call',
        functionName: 'Path.exists',
        arguments: ['/tmp'],
        callId: 1,
      );

      await monty.start('x');

      // Active state — cannot run() or start().
      expect(() => monty.run('y'), throwsStateError);
      expect(() => monty.start('y'), throwsStateError);
    });
  });

  // ===========================================================================
  // Async/Futures (M13) — forward-compat state handling
  // ===========================================================================
  group('async/futures (M13)', () {
    test(
      'start() returns MontyResolveFutures for resolve_futures state',
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
      },
    );

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
