import 'dart:typed_data';

import 'package:dart_monty_wasm/src/wasm_bindings.dart';
import 'package:dart_monty_wasm/src/wasm_core_bindings.dart';
import 'package:test/test.dart';

import 'mock_wasm_bindings.dart';

void main() {
  late MockWasmBindings mock;
  late WasmCoreBindings bindings;

  setUp(() {
    mock = MockWasmBindings();
    bindings = WasmCoreBindings(bindings: mock);
  });

  // ===========================================================================
  // init()
  // ===========================================================================
  group('init()', () {
    test('returns true on success', () async {
      expect(await bindings.init(), isTrue);
      expect(mock.initCalls, 1);
    });

    test('is idempotent', () async {
      await bindings.init();
      await bindings.init();
      expect(mock.initCalls, 1);
    });

    test('throws StateError on failure', () async {
      mock.nextInitResult = false;
      expect(bindings.init, throwsStateError);
    });
  });

  // ===========================================================================
  // run()
  // ===========================================================================
  group('run()', () {
    test('success translates to CoreRunResult with usage', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 42);

      final result = await bindings.run('42');

      expect(result.ok, isTrue);
      expect(result.value, 42);
      expect(result.usage, isNotNull);
      expect(result.usage!.memoryBytesUsed, 0);
      expect(result.usage!.timeElapsedMs, greaterThanOrEqualTo(0));
      expect(result.usage!.stackDepthUsed, 0);
    });

    test('passes limitsJson and scriptName', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);

      await bindings.run(
        'x',
        limitsJson: '{"timeout_ms":500}',
        scriptName: 'test.py',
      );

      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.limitsJson, '{"timeout_ms":500}');
      expect(mock.runCalls.first.scriptName, 'test.py');
    });

    test('error translates to CoreRunResult(ok: false)', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'SyntaxError',
        excType: 'SyntaxError',
        traceback: [
          {'filename': '<input>', 'start_line': 1},
        ],
      );

      final result = await bindings.run('def');

      expect(result.ok, isFalse);
      expect(result.error, 'SyntaxError');
      expect(result.excType, 'SyntaxError');
      expect(result.traceback, hasLength(1));
    });

    test('error with null message defaults to Unknown error', () async {
      mock.nextRunResult = const WasmRunResult(ok: false);

      final result = await bindings.run('x');

      expect(result.ok, isFalse);
      expect(result.error, 'Unknown error');
    });

    test('success with null value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true);

      final result = await bindings.run('None');

      expect(result.ok, isTrue);
      expect(result.value, isNull);
    });
  });

  // ===========================================================================
  // start()
  // ===========================================================================
  group('start()', () {
    test('complete translates to CoreProgressResult', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
        value: 42,
      );

      final result = await bindings.start('42');

      expect(result.state, 'complete');
      expect(result.value, 42);
      expect(result.usage, isNotNull);
      expect(result.usage!.timeElapsedMs, greaterThanOrEqualTo(0));
    });

    test('pending translates with all fields', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: ['url'],
        kwargs: {'timeout': 30},
        callId: 7,
        methodCall: true,
      );

      final result = await bindings.start(
        'x',
        extFnsJson: '["fetch"]',
      );

      expect(result.state, 'pending');
      expect(result.functionName, 'fetch');
      expect(result.arguments, ['url']);
      expect(result.kwargs, {'timeout': 30});
      expect(result.callId, 7);
      expect(result.methodCall, isTrue);
      expect(mock.startCalls.first.extFnsJson, '["fetch"]');
    });

    test('pending with null fields uses defaults', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
      );

      final result = await bindings.start('x');

      expect(result.functionName, '');
      expect(result.arguments, isEmpty);
      expect(result.kwargs, isNull);
      expect(result.callId, 0);
      expect(result.methodCall, isFalse);
    });

    test('error progress translates to error state', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'compilation failed',
        excType: 'CompileError',
        traceback: [
          {'filename': 'test.py', 'start_line': 5},
        ],
      );

      final result = await bindings.start('bad');

      expect(result.state, 'error');
      expect(result.error, 'compilation failed');
      expect(result.excType, 'CompileError');
      expect(result.traceback, hasLength(1));
    });

    test('resolve_futures translates pending call IDs', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0, 1, 2],
      );

      final result = await bindings.start('x');

      expect(result.state, 'resolve_futures');
      expect(result.pendingCallIds, [0, 1, 2]);
    });

    test('unknown state throws StateError', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'unknown',
      );

      expect(() => bindings.start('x'), throwsStateError);
    });

    test('passes limitsJson and scriptName', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await bindings.start(
        'x',
        limitsJson: '{"memory_bytes":512}',
        scriptName: 'script.py',
      );

      expect(mock.startCalls.first.limitsJson, '{"memory_bytes":512}');
      expect(mock.startCalls.first.scriptName, 'script.py');
    });
  });

  // ===========================================================================
  // resume()
  // ===========================================================================
  group('resume()', () {
    test('delegates valueJson and translates result', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'done',
        ),
      );

      final result = await bindings.resume('"hello"');

      expect(result.state, 'complete');
      expect(result.value, 'done');
      expect(mock.resumeCalls, ['"hello"']);
    });

    test('error translates to error state', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'runtime error',
        ),
      );

      final result = await bindings.resume('null');

      expect(result.state, 'error');
      expect(result.error, 'runtime error');
    });
  });

  // ===========================================================================
  // resumeWithError()
  // ===========================================================================
  group('resumeWithError()', () {
    test('delegates errorMessage and translates result', () async {
      mock.resumeWithErrorResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
        ),
      );

      final result = await bindings.resumeWithError('network failure');

      expect(result.state, 'complete');
      expect(mock.resumeWithErrorCalls, ['network failure']);
    });
  });

  // ===========================================================================
  // resumeAsFuture() / resolveFutures()
  // ===========================================================================
  group('resumeAsFuture()', () {
    test('delegates and translates result', () async {
      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0, 1],
        ),
      );

      final result = await bindings.resumeAsFuture();

      expect(result.state, 'resolve_futures');
      expect(result.pendingCallIds, [0, 1]);
      expect(mock.resumeAsFutureCalls, 1);
    });

    test('error translates to error state', () async {
      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'no active snapshot',
        ),
      );

      final result = await bindings.resumeAsFuture();

      expect(result.state, 'error');
      expect(result.error, 'no active snapshot');
    });
  });

  group('resolveFutures()', () {
    test('delegates and translates result', () async {
      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 42,
        ),
      );

      final result = await bindings.resolveFutures(
        '{"0": 10}',
        '{}',
      );

      expect(result.state, 'complete');
      expect(result.value, 42);
      expect(mock.resolveFuturesCalls, hasLength(1));
      expect(mock.resolveFuturesCalls.first.resultsJson, '{"0": 10}');
      expect(mock.resolveFuturesCalls.first.errorsJson, '{}');
    });

    test('error translates to error state', () async {
      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'no active future snapshot',
        ),
      );

      final result = await bindings.resolveFutures('{}', '{}');

      expect(result.state, 'error');
      expect(result.error, 'no active future snapshot');
    });
  });

  // ===========================================================================
  // snapshot() / restoreSnapshot()
  // ===========================================================================
  group('snapshot()', () {
    test('delegates to bindings', () async {
      mock.nextSnapshotData = Uint8List.fromList([10, 20, 30]);

      final data = await bindings.snapshot();

      expect(data, Uint8List.fromList([10, 20, 30]));
      expect(mock.snapshotCalls, 1);
    });
  });

  group('restoreSnapshot()', () {
    test('delegates to bindings', () async {
      final data = Uint8List.fromList([1, 2, 3]);

      await bindings.restoreSnapshot(data);

      expect(mock.restoreCalls, hasLength(1));
      expect(mock.restoreCalls.first, data);
    });
  });

  // ===========================================================================
  // dispose()
  // ===========================================================================
  group('dispose()', () {
    test('calls bindings dispose when initialized', () async {
      await bindings.init();
      await bindings.dispose();
      expect(mock.disposeCalls, 1);
    });

    test('does not call bindings dispose when not initialized', () async {
      await bindings.dispose();
      expect(mock.disposeCalls, 0);
    });
  });

  // ===========================================================================
  // Async/Futures Stress Tests (Tier 14)
  // ===========================================================================
  group('async/futures stress', () {
    // -----------------------------------------------------------------------
    // Multi-round resolution
    // -----------------------------------------------------------------------
    test('resumeAsFuture → resolveFutures full cycle', () async {
      // pending
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: ['url'],
        callId: 0,
      );
      final start = await bindings.start('x');
      expect(start.state, 'pending');
      expect(start.functionName, 'fetch');
      expect(start.callId, 0);

      // resumeAsFuture → resolve_futures
      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0],
        ),
      );
      final rf = await bindings.resumeAsFuture();
      expect(rf.state, 'resolve_futures');
      expect(rf.pendingCallIds, [0]);

      // resolveFutures → complete
      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'response_data',
        ),
      );
      final complete = await bindings.resolveFutures(
        '{"0": "response_data"}',
        '{}',
      );
      expect(complete.state, 'complete');
      expect(complete.value, 'response_data');
      expect(complete.usage, isNotNull);
    });

    test('multiple rounds: resolve yields new pending then new resolve',
        () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        callId: 0,
      );
      await bindings.start('x');

      // Round 1: resumeAsFuture → resolve_futures
      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0],
        ),
      );
      await bindings.resumeAsFuture();

      // Round 1: resolve → new pending
      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'g',
          arguments: [2],
          callId: 1,
        ),
      );
      final p2 = await bindings.resolveFutures('{"0": 10}', '{}');
      expect(p2.state, 'pending');
      expect(p2.functionName, 'g');

      // Round 2: resumeAsFuture → resolve_futures
      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [1],
        ),
      );
      await bindings.resumeAsFuture();

      // Round 2: resolve → complete
      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 42,
        ),
      );
      final complete = await bindings.resolveFutures('{"1": 20}', '{}');
      expect(complete.state, 'complete');
      expect(complete.value, 42);
    });

    // -----------------------------------------------------------------------
    // Scale: many pending IDs
    // -----------------------------------------------------------------------
    test('resolve with 20 pending call IDs', () async {
      final ids = List.generate(20, (i) => i);
      mock.nextStartResult = WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: ids,
      );
      final start = await bindings.start('x');
      expect(start.pendingCallIds, ids);

      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 190,
        ),
      );
      final complete = await bindings.resolveFutures(
        '{${ids.map((i) => '"$i": $i').join(', ')}}',
        '{}',
      );
      expect(complete.state, 'complete');
      expect(complete.value, 190);
    });

    // -----------------------------------------------------------------------
    // Error propagation
    // -----------------------------------------------------------------------
    test('resumeAsFuture error translates to error state', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        callId: 0,
      );
      await bindings.start('x');

      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'no active snapshot',
          excType: 'StateError',
        ),
      );

      final result = await bindings.resumeAsFuture();
      expect(result.state, 'error');
      expect(result.error, 'no active snapshot');
    });

    test('resolveFutures error with traceback', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0],
      );
      await bindings.start('x');

      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: false,
          error: 'division by zero',
          excType: 'ZeroDivisionError',
          traceback: [
            {'filename': 'main.py', 'start_line': 3},
          ],
        ),
      );

      final result = await bindings.resolveFutures('{"0": 0}', '{}');
      expect(result.state, 'error');
      expect(result.error, 'division by zero');
      expect(result.excType, 'ZeroDivisionError');
    });

    // -----------------------------------------------------------------------
    // Timing: wall-clock timing is captured
    // -----------------------------------------------------------------------
    test('resumeAsFuture captures wall-clock timing', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        callId: 0,
      );
      await bindings.start('x');

      mock.resumeAsFutureResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 42,
        ),
      );

      final result = await bindings.resumeAsFuture();
      expect(result.state, 'complete');
      expect(result.usage, isNotNull);
      expect(result.usage!.timeElapsedMs, greaterThanOrEqualTo(0));
    });

    test('resolveFutures captures wall-clock timing', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0],
      );
      await bindings.start('x');

      mock.resolveFuturesResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 42,
        ),
      );

      final result = await bindings.resolveFutures('{"0": 42}', '{}');
      expect(result.state, 'complete');
      expect(result.usage, isNotNull);
      expect(result.usage!.timeElapsedMs, greaterThanOrEqualTo(0));
    });

    // -----------------------------------------------------------------------
    // Call tracking fidelity
    // -----------------------------------------------------------------------
    test('resumeAsFuture increments call counter', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        callId: 0,
      );
      await bindings.start('x');

      mock.resumeAsFutureResults.addAll([
        const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'g',
          callId: 1,
        ),
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [0, 1],
        ),
      ]);

      await bindings.resumeAsFuture();
      await bindings.resumeAsFuture();
      expect(mock.resumeAsFutureCalls, 2);
    });

    test('resolveFutures records all call arguments', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'resolve_futures',
        pendingCallIds: [0, 1],
      );
      await bindings.start('x');

      mock.resolveFuturesResults.addAll([
        const WasmProgressResult(
          ok: true,
          state: 'resolve_futures',
          pendingCallIds: [2],
        ),
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'done',
        ),
      ]);

      await bindings.resolveFutures('{"0":"a","1":"b"}', '{}');
      await bindings.resolveFutures('{"2":"c"}', '{"3":"err"}');

      expect(mock.resolveFuturesCalls, hasLength(2));
      expect(mock.resolveFuturesCalls[0].resultsJson, '{"0":"a","1":"b"}');
      expect(mock.resolveFuturesCalls[0].errorsJson, '{}');
      expect(mock.resolveFuturesCalls[1].resultsJson, '{"2":"c"}');
      expect(mock.resolveFuturesCalls[1].errorsJson, '{"3":"err"}');
    });
  });
}
