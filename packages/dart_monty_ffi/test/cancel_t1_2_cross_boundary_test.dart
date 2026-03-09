@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

/// T1-2: Cross-Boundary CancelToken Routing
///
/// Verifies that MontyCancelToken.cancel() correctly routes cancellation
/// across isolate boundaries. The token is obtained from the worker isolate's
/// handleId and used to cancel from the supervisor (test) context.
void main() {
  const infiniteLoop = 'while True: pass';
  final libPath = _resolveLibraryPath();

  group('cross-isolate token cancel', () {
    for (var trial = 1; trial <= 5; trial++) {
      test('trial $trial: token.cancel() halts worker', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        // Wait for handleId to arrive via _HandleIdNotification.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final hid = isolate.handleId;
        expect(hid, isNotNull, reason: 'handleId should be set after start');
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
      final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final hid = isolate.handleId!;
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
      final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
      await isolate.init();

      final startFuture = isolate.start(
        infiniteLoop,
        externalFunctions: ['__never_called__'],
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final hid = isolate.handleId!;

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
