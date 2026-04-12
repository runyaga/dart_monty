import 'package:dart_monty/src/wasm/wasm_bindings.dart';
import 'package:dart_monty/src/wasm/wasm_core_bindings.dart';
import 'package:test/test.dart';

import 'mock_wasm_bindings.dart';

void main() {
  group('multi-session routing', () {
    late MockWasmBindings mock;

    setUp(() {
      mock = MockWasmBindings();
    });

    test('two WasmCoreBindings instances get different session IDs', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      expect(mock.createSessionCalls, 2);
    });

    test('run() routes to correct session per instance', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init(); // gets sessionId 1
      await b2.init(); // gets sessionId 2

      await b1.run('code_for_session_1');
      await b2.run('code_for_session_2');

      expect(mock.runCalls, hasLength(2));
      expect(mock.runCalls[0].sessionId, 1);
      expect(mock.runCalls[0].code, 'code_for_session_1');
      expect(mock.runCalls[1].sessionId, 2);
      expect(mock.runCalls[1].code, 'code_for_session_2');
    });

    test('start() routes to correct session per instance', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.start('s1');
      await b2.start('s2');

      expect(mock.startCalls, hasLength(2));
      expect(mock.startCalls[0].sessionId, 1);
      expect(mock.startCalls[1].sessionId, 2);
    });

    test('resume() routes to correct session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.resume('"val1"');
      await b2.resume('"val2"');

      expect(mock.resumeCalls, hasLength(2));
      expect(mock.resumeCalls[0].sessionId, 1);
      expect(mock.resumeCalls[1].sessionId, 2);
    });

    test('resumeWithError() routes to correct session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.resumeWithError('err1');
      await b2.resumeWithError('err2');

      expect(mock.resumeWithErrorCalls, hasLength(2));
      expect(mock.resumeWithErrorCalls[0].sessionId, 1);
      expect(mock.resumeWithErrorCalls[1].sessionId, 2);
    });

    test('resumeAsFuture() routes to correct session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.resumeAsFuture();
      await b2.resumeAsFuture();

      expect(mock.resumeAsFutureSessionIds, [1, 2]);
    });

    test('resolveFutures() routes to correct session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.resolveFutures('{}', '{}');
      await b2.resolveFutures('{}', '{}');

      expect(mock.resolveFuturesCalls, hasLength(2));
      expect(mock.resolveFuturesCalls[0].sessionId, 1);
      expect(mock.resolveFuturesCalls[1].sessionId, 2);
    });

    test('snapshot() routes to correct session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.snapshot();
      await b2.snapshot();

      expect(mock.snapshotSessionIds, [1, 2]);
    });

    test('dispose routes to correct session via disposeSession', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      await b1.dispose();

      // disposeSession called with session 1 only
      expect(mock.disposeSessionCalls, [1]);

      await b2.dispose();

      expect(mock.disposeSessionCalls, [1, 2]);
    });

    test('dispose one session does not affect the other', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();
      await b1.dispose();

      // b2 still works after b1 is disposed
      await b2.run('still alive');

      expect(mock.runCalls, hasLength(1));
      expect(mock.runCalls.first.sessionId, 2);
    });

    test('N concurrent sessions get unique IDs', () async {
      const n = 5;
      final instances = <WasmCoreBindings>[];
      for (var i = 0; i < n; i++) {
        final b = WasmCoreBindings(bindings: mock);
        await b.init();
        instances.add(b);
      }

      expect(mock.createSessionCalls, n);

      // Each run routes to its own session
      for (var i = 0; i < n; i++) {
        await instances[i].run('code_$i');
      }

      expect(mock.runCalls, hasLength(n));
      for (var i = 0; i < n; i++) {
        expect(mock.runCalls[i].sessionId, i + 1);
      }

      // Clean up
      for (final b in instances) {
        await b.dispose();
      }
    });

    test('session invalidation after panic is per-session', () async {
      final b1 = WasmCoreBindings(bindings: mock);
      final b2 = WasmCoreBindings(bindings: mock);

      await b1.init();
      await b2.init();

      expect(mock.createSessionCalls, 2);

      // b1 panics — session invalidated
      mock.nextRunResult = const WasmRunResult(
        ok: false,
        error: 'WASM trap',
        errorType: 'Panic',
      );

      try {
        await b1.run('panic');
      } on Object catch (_) {
        // Expected MontyPanicError
      }

      // b2 is unaffected — still uses session 2
      mock.nextRunResult = const WasmRunResult(ok: true, value: 42);
      await b2.run('fine');

      expect(mock.runCalls.last.sessionId, 2);

      // b1 re-inits to a new session (3)
      await b1.init();
      expect(mock.createSessionCalls, 3);

      await b1.run('recovered');
      expect(mock.runCalls.last.sessionId, 3);
    });
  });
}
