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

/// T1-3: Terminate Resource Release
///
/// Verifies that terminate() frees ALL resources: the Rust MontyHandle
/// (via freeById), the handleId reference, and the isolate.
void main() {
  const infiniteLoop = 'while True: pass';
  final libPath = _resolveLibraryPath();

  group('terminate resource cleanup', () {
    for (var trial = 1; trial <= 5; trial++) {
      test('trial $trial: terminate frees Rust registry entry', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        final hid = isolate.handleId;
        expect(hid, isNotNull);
        expect(hid, greaterThan(0));

        // Before terminate: handle exists in Rust registry.
        final preState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        expect(preState, isNotNull, reason: 'handle should be in registry');

        // Guard startFuture so its error does not escape the test zone
        // during the terminate() await.
        Object? startError;
        unawaited(
          startFuture.then<void>(
            (_) {},
            onError: (Object e) {
              startError = e;
            },
          ),
        );

        await isolate.terminate();

        expect(
          startError,
          anyOf(isA<MontyCancelledError>(), isA<MontyException>()),
        );

        // After terminate: handleId should be null on the Dart side.
        expect(isolate.handleId, isNull);

        // After terminate: Rust registry should not contain the handle.
        final postState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        expect(
          postState,
          isNull,
          reason: 'handle should be freed from Rust registry',
        );
      });
    }
  });

  group('zombie tracking', () {
    test('zombie count starts at zero or a known baseline', () {
      // Just verify the static counter is accessible. It should be zero
      // if no tests have triggered zombie conditions.
      expect(NativeIsolateBindingsImpl.zombieCount, greaterThanOrEqualTo(0));
    });
  });
}
