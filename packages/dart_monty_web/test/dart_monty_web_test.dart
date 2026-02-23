import 'dart:typed_data';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';
import 'package:dart_monty_web/dart_monty_web.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_wasm_bindings.dart';

void main() {
  late MockWasmBindings mock;
  late DartMontyWeb web;

  setUp(() {
    mock = MockWasmBindings();
    web = DartMontyWeb.withBindings(mock);
  });

  tearDown(() async {
    await web.dispose();
  });

  // ===========================================================================
  // registerWith()
  // ===========================================================================
  group('registerWith()', () {
    test('sets MontyPlatform.instance', () {
      final testWeb = DartMontyWeb.withBindings(mock);
      MontyPlatform.instance = testWeb;
      addTearDown(() => MontyPlatform.instance = testWeb);

      expect(MontyPlatform.instance, isA<DartMontyWeb>());
      expect(identical(MontyPlatform.instance, testWeb), isTrue);
    });

    test('instance is a MontyPlatform', () {
      expect(web, isA<MontyPlatform>());
    });
  });

  // ===========================================================================
  // run()
  // ===========================================================================
  group('run()', () {
    test('returns result from delegate', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 4);

      final result = await web.run('2 + 2');

      expect(result.value, 4);
      expect(result.isError, isFalse);
      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.code, '2 + 2');
    });

    test('auto-initializes on first call', () async {
      await web.run('1');
      expect(mock.initCalls, 1);
    });

    test('does not re-initialize after first call', () async {
      await web.run('1');
      await web.run('2');
      expect(mock.initCalls, 1);
    });

    test('passes limits as JSON to delegate', () async {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 500,
        stackDepth: 10,
      );

      await web.run('x', limits: limits);

      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.limitsJson, isNotNull);
    });

    test('passes null limits when none provided', () async {
      await web.run('1');
      expect(mock.runCalls.first.limitsJson, isNull);
    });

    test('throws MontyException on error result', () async {
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'NameError: x is not defined',
      );

      expect(
        () => web.run('x'),
        throwsA(isA<MontyException>()),
      );
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => web.run('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('allows null inputs', () async {
      // ignore: avoid_redundant_argument_values
      final result = await web.run('1', inputs: null);
      expect(result.value, 4);
    });

    test('allows empty inputs', () async {
      final result = await web.run('1', inputs: {});
      expect(result.value, 4);
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(() => web.run('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
      );
      await web.start('x', externalFunctions: ['fetch']);

      expect(() => web.run('y'), throwsStateError);
    });

    test('returns null value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true);

      final result = await web.run('None');
      expect(result.value, isNull);
      expect(result.isError, isFalse);
    });

    test('returns string value', () async {
      mock.nextRunResult = const WasmRunResult(ok: true, value: 'hello');

      final result = await web.run('"hello"');
      expect(result.value, 'hello');
    });

    test('resource usage is synthetic zeros', () async {
      final result = await web.run('1');
      expect(result.usage.memoryBytesUsed, 0);
      expect(result.usage.timeElapsedMs, 0);
      expect(result.usage.stackDepthUsed, 0);
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

      final progress = await web.start('42');

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

      final progress = await web.start(
        'fetch("https://example.com")',
        externalFunctions: ['fetch'],
      );

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'fetch');
      expect(pending.arguments, ['https://example.com']);
    });

    test('passes external functions as JSON', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'a',
        arguments: [],
      );

      await web.start('a()', externalFunctions: ['a', 'b', 'c']);

      expect(mock.startCalls.first.extFnsJson, '["a","b","c"]');
    });

    test('passes null extFnsJson when empty list', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await web.start('x', externalFunctions: []);

      expect(mock.startCalls.first.extFnsJson, isNull);
    });

    test('passes null extFnsJson when null', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );

      await web.start('x');

      expect(mock.startCalls.first.extFnsJson, isNull);
    });

    test('throws MontyException on error', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'SyntaxError',
      );

      expect(
        () => web.start('invalid code!!!'),
        throwsA(isA<MontyException>()),
      );
    });

    test('throws UnsupportedError for non-empty inputs', () {
      expect(
        () => web.start('x', inputs: {'a': 1}),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(() => web.start('x'), throwsStateError);
    });

    test('throws StateError when active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
      );
      await web.start('x', externalFunctions: ['f']);

      expect(() => web.start('y'), throwsStateError);
    });

    test('passes limits', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );
      const limits = MontyLimits(memoryBytes: 512);

      await web.start('x', limits: limits);

      expect(mock.startCalls.first.limitsJson, isNotNull);
    });
  });

  // ===========================================================================
  // resume()
  // ===========================================================================
  group('resume()', () {
    setUp(() async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'fetch',
        arguments: [],
      );
      await web.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete when execution finishes', () async {
      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'hello',
        ),
      );

      final progress = await web.resume('response');

      expect(progress, isA<MontyComplete>());
      expect(mock.resumeCalls, hasLength(1));
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

      final progress = await web.resume('response');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'save');
      expect(pending.arguments, ['data']);
    });

    test('throws StateError when idle', () async {
      mock.resumeResults.add(
        const WasmProgressResult(ok: true, state: 'complete'),
      );
      await web.resume(null);

      expect(() => web.resume(null), throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(() => web.resume(null), throwsStateError);
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
      await web.start('x', externalFunctions: ['fetch']);
    });

    test('returns MontyComplete after error injection', () async {
      mock.resumeWithErrorResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'complete',
          value: 'caught',
        ),
      );

      final progress = await web.resumeWithError('network failure');

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

      final progress = await web.resumeWithError('timeout');

      expect(progress, isA<MontyPending>());
      final pending = progress as MontyPending;
      expect(pending.functionName, 'retry');
    });

    test('throws StateError when idle', () {
      final freshWeb = DartMontyWeb.withBindings(mock);
      expect(
        () => freshWeb.resumeWithError('err'),
        throwsStateError,
      );
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(
        () => web.resumeWithError('err'),
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
      await web.start('x', externalFunctions: ['f']);
    });

    test('returns snapshot bytes', () async {
      mock.nextSnapshotData = Uint8List.fromList([10, 20, 30]);

      final data = await web.snapshot();

      expect(data, Uint8List.fromList([10, 20, 30]));
      expect(mock.snapshotCalls, 1);
    });

    test('throws StateError when idle', () {
      final freshWeb = DartMontyWeb.withBindings(mock);
      expect(freshWeb.snapshot, throwsStateError);
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(() => web.snapshot(), throwsStateError);
    });
  });

  // ===========================================================================
  // restore()
  // ===========================================================================
  group('restore()', () {
    test('returns new MontyPlatform instance', () async {
      final data = Uint8List.fromList([1, 2, 3]);

      final restored = await web.restore(data);

      expect(restored, isA<MontyPlatform>());
      expect(mock.restoreCalls, hasLength(1));
      expect(mock.restoreCalls.first, data);
    });

    test('throws StateError when disposed', () async {
      await web.dispose();
      expect(
        () => web.restore(Uint8List.fromList([1])),
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
      await web.start('x', externalFunctions: ['f']);

      expect(
        () => web.restore(Uint8List.fromList([1])),
        throwsStateError,
      );
    });
  });

  // ===========================================================================
  // dispose()
  // ===========================================================================
  group('dispose()', () {
    test('calls delegate dispose when initialized', () async {
      await web.run('1');
      await web.dispose();
      expect(mock.disposeCalls, 1);
    });

    test('does not call delegate dispose when not initialized', () async {
      await web.dispose();
      expect(mock.disposeCalls, 0);
    });

    test('double dispose is safe', () async {
      await web.run('1');
      await web.dispose();
      await web.dispose();
      expect(mock.disposeCalls, 1);
    });

    test('disposed instance rejects all methods', () async {
      await web.dispose();

      expect(() => web.run('x'), throwsStateError);
      expect(() => web.start('x'), throwsStateError);
      expect(() => web.resume(null), throwsStateError);
      expect(() => web.resumeWithError('e'), throwsStateError);
      expect(() => web.snapshot(), throwsStateError);
      expect(() => web.restore(Uint8List(0)), throwsStateError);
    });
  });

  // ===========================================================================
  // State machine transitions
  // ===========================================================================
  group('state machine', () {
    test('idle -> run -> idle', () async {
      await web.run('1');

      mock.nextRunResult = const WasmRunResult(ok: true, value: 2);
      final result = await web.run('2');
      expect(result.value, 2);
    });

    test('idle -> start(complete) -> idle', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
        value: 42,
      );

      await web.start('42');

      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      final result = await web.run('1');
      expect(result.value, 1);
    });

    test(
      'idle -> start(pending) -> active -> resume(complete) -> idle',
      () async {
        mock.nextStartResult = const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'f',
          arguments: [],
        );

        await web.start('x', externalFunctions: ['f']);

        mock.resumeResults.add(
          const WasmProgressResult(
            ok: true,
            state: 'complete',
            value: 'done',
          ),
        );

        final progress = await web.resume('value');
        expect(progress, isA<MontyComplete>());

        mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
        final result = await web.run('1');
        expect(result.value, 1);
      },
    );

    test('active -> resume(pending) -> still active', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'a',
        arguments: [],
      );
      await web.start('x', externalFunctions: ['a', 'b']);

      mock.resumeResults.add(
        const WasmProgressResult(
          ok: true,
          state: 'pending',
          functionName: 'b',
          arguments: ['arg'],
        ),
      );

      final progress = await web.resume('val');
      expect(progress, isA<MontyPending>());

      mock.resumeResults.add(
        const WasmProgressResult(ok: true, state: 'complete'),
      );
      final done = await web.resume('val2');
      expect(done, isA<MontyComplete>());
    });

    test('active -> dispose -> disposed', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'pending',
        functionName: 'f',
        arguments: [],
      );
      await web.start('x', externalFunctions: ['f']);

      await web.dispose();

      expect(() => web.run('x'), throwsStateError);
    });

    test('error during start resets to idle', () async {
      mock.nextStartResult = const WasmProgressResult(
        ok: false,
        error: 'SyntaxError',
      );

      expect(
        () => web.start('bad'),
        throwsA(isA<MontyException>()),
      );

      mock.nextRunResult = const WasmRunResult(ok: true, value: 1);
      final result = await web.run('1');
      expect(result.value, 1);
    });
  });

  // ===========================================================================
  // Auto-init
  // ===========================================================================
  group('auto-init', () {
    test('first call auto-initializes', () async {
      await web.run('1');
      expect(mock.initCalls, 1);
    });

    test('initialization is idempotent', () async {
      await web.run('1');
      await web.run('2');
      mock.nextStartResult = const WasmProgressResult(
        ok: true,
        state: 'complete',
      );
      await web.start('3');
      expect(mock.initCalls, 1);
    });
  });
}
