@Tags(['integration'])
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print, lines_longer_than_80_chars

import 'dart:async';
import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// EXP-CANCEL-T1-4: Sealed Error Routing — Integration Tests
///
/// N=50 per sub-experiment (A: Python exception, C: Cancel, D: Dispose during run).
/// Sub-B (OOM) and Sub-E (Rust panic) require test-only FFI paths; skipped if unavailable.
void main() {
  // --- Metrics ---
  var subACorrect = 0;
  var subCCorrect = 0;
  var subDCorrect = 0;
  final subAWrongTypes = <String>[];
  final subCWrongTypes = <String>[];
  final subDWrongTypes = <String>[];
  const n = 50;

  group('T1-4A: Python exception → MontyException (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial: ZeroDivisionError', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        try {
          await isolate.run('1/0');
          subAWrongTypes.add('no exception');
        } on MontyException catch (e) {
          if (e.excType == 'ZeroDivisionError') {
            subACorrect++;
          } else {
            subAWrongTypes.add('MontyException(${e.excType})');
          }
        } on Object catch (e) {
          subAWrongTypes.add(e.runtimeType.toString());
        }

        await isolate.dispose();
      });
    }
  });

  group('T1-4C: Cancel → MontyCancelledError (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        final startFuture = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));
        await isolate.cancel();

        try {
          await startFuture;
          subCWrongTypes.add('no exception');
        } on MontyCancelledError {
          subCCorrect++;
        } on Object catch (e) {
          subCWrongTypes.add(e.runtimeType.toString());
        }

        await isolate.terminate();
      });
    }
  });

  group('T1-4D: Dispose during run → error resolution (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test(
        'trial $trial',
        () async {
          final isolate = NativeIsolateBindingsImpl();
          await isolate.init();

          final startFuture = isolate.start(
            'while True: pass',
            externalFunctions: ['__never_called__'],
          );

          await Future<void>.delayed(const Duration(milliseconds: 100));

          // dispose() without cancel — should still resolve the Future.
          // Use terminate() which has a built-in 5s timeout for stuck isolates.
          Object? caughtError;
          unawaited(
            startFuture.then<void>(
              (_) {},
              onError: (Object e) {
                caughtError = e;
              },
            ),
          );

          await isolate.terminate();

          // Give async error propagation a moment.
          await Future<void>.delayed(const Duration(milliseconds: 100));

          if (caughtError is MontyDisposedError ||
              caughtError is MontyCancelledError ||
              caughtError is MontyCrashError) {
            subDCorrect++;
          } else {
            subDWrongTypes.add(
              caughtError?.runtimeType.toString() ??
                  'null (Future still pending)',
            );
          }
        },
        timeout: const Timeout(Duration(seconds: 10)),
      );
    }
  });

  tearDownAll(() {
    print('\n=== EXP-CANCEL-T1-4 RESULTS ===');
    print('Sub-A (Python exc → MontyException): $subACorrect / $n');
    if (subAWrongTypes.isNotEmpty) print('  Wrong: $subAWrongTypes');
    print('Sub-C (Cancel → MontyCancelledError): $subCCorrect / $n');
    if (subCWrongTypes.isNotEmpty) print('  Wrong: $subCWrongTypes');
    print('Sub-D (Dispose → MontyDisposedError/CrashError): $subDCorrect / $n');
    if (subDWrongTypes.isNotEmpty) print('  Wrong: $subDWrongTypes');
    print('Sub-B (OOM): SKIPPED (needs MontyLimits.memoryBytes integration)');
    print('Sub-E (Rust panic): SKIPPED (needs test-only FFI path)');
    print('');
    print(
      'VERDICT: '
      '${subACorrect == n && subCCorrect == n && subDCorrect == n ? "PASS" : "FAIL (with caveats for skipped sub-experiments)"}',
    );
    print('=== END T1-4 ===\n');
  });
}
