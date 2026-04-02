@Tags(['integration'])
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print, lines_longer_than_80_chars

import 'dart:async';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// EXP-CANCEL-T1-3: Terminate Resource Release
///
/// N=100 terminate trials.
/// Verifies 100% Rust registry freed, 100% Dart references nulled.
void main() {
  const infiniteLoop = 'while True: pass';

  // --- Metrics ---
  var registryFreedCount = 0;
  var handleIdNulledCount = 0;
  var registryNotFreedCount = 0;
  var handleIdNotNulledCount = 0;
  const n = 100;

  group('T1-3: terminate resource release (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        final hid = isolate.handleId;
        expect(hid, isNotNull);

        // Verify handle exists pre-terminate.
        final preState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        expect(preState, isNotNull, reason: 'handle should be in registry');

        // Guard startFuture.
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

        // Check Dart-side cleanup.
        if (isolate.handleId == null) {
          handleIdNulledCount++;
        } else {
          handleIdNotNulledCount++;
        }

        // Check Rust registry cleanup.
        final postState = NativeBindingsFfi.instanceOrNull?.isCancelledById(
          hid!,
        );
        if (postState == null) {
          registryFreedCount++;
        } else {
          registryNotFreedCount++;
        }
      });
    }
  });

  tearDownAll(() {
    print('\n=== EXP-CANCEL-T1-3 RESULTS ===');
    print('Trials: $n');
    print('Rust registry freed: $registryFreedCount / $n');
    print('Rust registry NOT freed: $registryNotFreedCount');
    print('handleId nulled: $handleIdNulledCount / $n');
    print('handleId NOT nulled: $handleIdNotNulledCount');
    print('');
    print(
      'VERDICT: '
      '${registryFreedCount == n && handleIdNulledCount == n ? "PASS" : "FAIL"}',
    );
    print('=== END T1-3 ===\n');
  });
}
