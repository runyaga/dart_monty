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

/// EXP-CANCEL-T1-2: Cross-Boundary CancelToken Routing
///
/// N=100 cross-isolate token cancel trials.
/// Verifies 100% cross-isolate cancel success, 0% StateError, 100% isAlive==false post-terminate.
void main() {
  const infiniteLoop = 'while True: pass';
  final libPath = _resolveLibraryPath();

  // --- Metrics ---
  var crossCancelSuccess = 0;
  var stateErrorCount = 0;
  var isAlivePostTerminate = 0; // should be 0 (all false)
  var autoInitSuccess = 0;
  const n = 100;

  group('T1-2: cross-isolate token cancel (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
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

        final token = MontyCancelToken(hid!);
        expect(token.isAlive, isTrue);

        // Token cancel from supervisor context (same isolate in test, but
        // exercises the FFI cancelById path).
        bool cancelled;
        try {
          cancelled = token.cancel();
          autoInitSuccess++;
        } on StateError {
          stateErrorCount++;
          cancelled = false;
        }

        if (cancelled) {
          try {
            await startFuture;
          } on MontyCancelledError {
            crossCancelSuccess++;
          } on Object {
            // Wrong exception type.
          }
        }

        await isolate.terminate();

        if (token.isAlive) {
          isAlivePostTerminate++;
        }
      });
    }
  });

  tearDownAll(() {
    print('\n=== EXP-CANCEL-T1-2 RESULTS ===');
    print('Trials: $n');
    print('Cross-isolate cancel success: $crossCancelSuccess / $n');
    print('StateError on auto-init: $stateErrorCount / $n');
    print('isAlive==true post-terminate: $isAlivePostTerminate / $n');
    print('Auto-init success: $autoInitSuccess / $n');
    print('');
    print('VERDICT: '
        '${crossCancelSuccess == n && stateErrorCount == 0 && isAlivePostTerminate == 0 ? "PASS" : "FAIL"}');
    print('=== END T1-2 ===\n');
  });
}
