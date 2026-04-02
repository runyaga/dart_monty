@Tags(['integration'])
library;

import 'dart:async';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// T1-1: End-to-End Cancellation & Idempotency
///
/// Verifies that cancel() reliably halts a running interpreter and surfaces
/// exactly MontyCancelledError, and that repeated cancellation is safe.
void main() {
  const infiniteLoop = 'while True: pass';
  const trivial = '2 + 2';

  // Pre-load native library so trial 1 doesn't timeout on cold start.
  setUpAll(() async {
    final warmUp = NativeIsolateBindingsImpl();
    await warmUp.init();
    await warmUp.run('1');
    await warmUp.dispose();
  });

  group('cancel during execution', () {
    for (var trial = 1; trial <= 5; trial++) {
      test(
        'trial $trial: cancel halts infinite loop with MontyCancelledError',
        () async {
          final isolate = NativeIsolateBindingsImpl();
          await isolate.init();

          final startFuture = isolate.start(
            infiniteLoop,
            externalFunctions: ['__never_called__'],
          );

          // Give the interpreter time to enter the infinite loop.
          await Future<void>.delayed(const Duration(milliseconds: 100));

          await isolate.cancel();

          await expectLater(
            startFuture,
            throwsA(isA<MontyCancelledError>()),
          );

          await isolate.terminate();
        },
      );
    }
  });

  group('double-cancel idempotency', () {
    test('second cancel does not throw', () async {
      final isolate = NativeIsolateBindingsImpl();
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // First cancel — triggers MontyCancelledError.
      await isolate.cancel();
      await expectLater(startFuture, throwsA(isA<MontyCancelledError>()));

      // Second cancel — should be a no-op, no throw.
      await expectLater(isolate.cancel(), completes);

      await isolate.terminate();
    });

    test('triple cancel does not throw', () async {
      final isolate = NativeIsolateBindingsImpl();
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      await isolate.cancel();
      await expectLater(startFuture, throwsA(isA<MontyCancelledError>()));

      // Second and third cancel — both should be no-ops.
      await expectLater(isolate.cancel(), completes);
      await expectLater(isolate.cancel(), completes);

      await isolate.terminate();
    });
  });

  group('cancel after completion', () {
    test('cancel on completed interpreter is a no-op', () async {
      final isolate = NativeIsolateBindingsImpl();
      await isolate.init();

      final result = await isolate.run(trivial);
      expect(result.value, 4);

      // Cancel after completion — should be a no-op.
      await expectLater(isolate.cancel(), completes);

      await isolate.dispose();
    });
  });
}
