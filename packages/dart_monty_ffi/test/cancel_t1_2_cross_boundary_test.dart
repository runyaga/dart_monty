@Tags(['integration'])
library;

import 'dart:async';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// T1-2: Cross-Boundary CancelToken Routing
///
/// Verifies that MontyCancelToken.cancel() correctly routes cancellation
/// across isolate boundaries. The token is obtained from the worker isolate's
/// handleId and used to cancel from the supervisor (test) context.
/// Polls for [isolate.handleId] to become non-null within [timeout].
Future<int> _waitForHandleId(
  NativeIsolateBindingsImpl isolate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (isolate.handleId == null) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('handleId not set within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return isolate.handleId!;
}

void main() {
  const infiniteLoop = 'while True: pass';

  // Pre-load native library so trial 1 doesn't timeout on cold start.
  setUpAll(() async {
    final warmUp = NativeIsolateBindingsImpl();
    await warmUp.init();
    await warmUp.run('1');
    await warmUp.dispose();
  });

  group('cross-isolate token cancel', () {
    for (var trial = 1; trial <= 5; trial++) {
      test('trial $trial: token.cancel() halts worker', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        // Wait for handleId to arrive via _HandleIdNotification.
        final hid = await _waitForHandleId(isolate);
        expect(hid, greaterThan(0));

        // Construct a cancel token and cancel from this isolate.
        final token = MontyCancelToken(hid!);
        expect(token.isAlive, isTrue);

        final cancelled = token.cancel();
        expect(cancelled, isTrue, reason: 'cancel should find the handle');

        await expectLater(
          startFuture,
          throwsA(isA<MontyCancelledError>()),
        );

        await isolate.terminate();
      });
    }
  });

  group('token.isAlive', () {
    test('isAlive is false after terminate', () async {
      final isolate = NativeIsolateBindingsImpl();
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      final hid = await _waitForHandleId(isolate);
      final token = MontyCancelToken(hid);

      expect(token.isAlive, isTrue);

      await isolate.cancel();
      try {
        await startFuture;
      } on MontyCancelledError {
        // Expected.
      }
      await isolate.terminate();

      expect(token.isAlive, isFalse);
    });
  });

  group('auto-initialization', () {
    test('token.cancel() auto-initializes FFI without StateError', () async {
      final isolate = NativeIsolateBindingsImpl();
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      final hid = await _waitForHandleId(isolate);

      // MontyCancelToken.cancel() calls BaseMontyPlatform.cancelById()
      // which calls NativeBindingsFfi.ensureInitialized() automatically.
      // This should not throw StateError.
      final token = MontyCancelToken(hid);
      expect(token.cancel, returnsNormally);

      try {
        await startFuture;
      } on MontyCancelledError {
        // Expected.
      }

      await isolate.terminate();
    });
  });
}
