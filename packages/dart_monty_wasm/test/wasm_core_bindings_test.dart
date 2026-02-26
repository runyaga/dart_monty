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
  group('unsupported methods', () {
    test('resumeAsFuture throws UnsupportedError', () {
      expect(bindings.resumeAsFuture, throwsUnsupportedError);
    });

    test('resolveFutures throws UnsupportedError', () {
      expect(
        () => bindings.resolveFutures('{}', '{}'),
        throwsUnsupportedError,
      );
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
}
