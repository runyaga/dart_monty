@Tags(['integration'])
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print, lines_longer_than_80_chars

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

/// EXP-CANCEL-T1-1: End-to-End Cancellation & Idempotency
///
/// N=200 cancel trials, N=200 double/triple cancel, N=50 post-completion cancel.
/// Verifies 100% MontyCancelledError, 0% double/triple throw, 0% post-complete throw.
void main() {
  const infiniteLoop = 'while True: pass';
  const trivial = '2 + 2';
  final libPath = _resolveLibraryPath();

  // --- Metrics accumulators ---
  var cancelledCount = 0;
  var wrongTypeCount = 0;
  final wrongTypes = <String>[];
  var doubleThrowCount = 0;
  var tripleThrowCount = 0;
  var postCompleteThrowCount = 0;

  const cancelN = 200;
  const postCompleteN = 50;

  group('T1-1A: cancel during execution (N=$cancelN)', () {
    for (var trial = 1; trial <= cancelN; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        final startFuture = isolate.start(
          infiniteLoop,
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));
        await isolate.cancel();

        try {
          await startFuture;
          // Should not reach here.
          wrongTypeCount++;
          wrongTypes.add('no exception thrown');
        } on MontyCancelledError {
          cancelledCount++;
        } on Object catch (e) {
          wrongTypeCount++;
          wrongTypes.add(e.runtimeType.toString());
        }

        // Double cancel — should not throw.
        try {
          await isolate.cancel();
        } on Object {
          doubleThrowCount++;
        }

        // Triple cancel — should not throw.
        try {
          await isolate.cancel();
        } on Object {
          tripleThrowCount++;
        }

        await isolate.terminate();
      });
    }
  });

  group('T1-1B: cancel after completion (N=$postCompleteN)', () {
    for (var trial = 1; trial <= postCompleteN; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        final result = await isolate.run(trivial);
        expect(result.value, 4);

        try {
          await isolate.cancel();
        } on Object {
          postCompleteThrowCount++;
        }

        await isolate.dispose();
      });
    }
  });

  tearDownAll(() {
    // Print metrics summary for evidence collection.
    print('\n=== EXP-CANCEL-T1-1 RESULTS ===');
    print('Cancel trials: $cancelN');
    print('MontyCancelledError count: $cancelledCount / $cancelN');
    print('Wrong exception types: $wrongTypeCount');
    if (wrongTypes.isNotEmpty) print('  Types seen: $wrongTypes');
    print('Double-cancel throw count: $doubleThrowCount / $cancelN');
    print('Triple-cancel throw count: $tripleThrowCount / $cancelN');
    print(
      'Post-completion throw count: $postCompleteThrowCount / $postCompleteN',
    );
    print('');
    print('VERDICT: '
        '${cancelledCount == cancelN && wrongTypeCount == 0 && doubleThrowCount == 0 && tripleThrowCount == 0 && postCompleteThrowCount == 0 ? "PASS" : "FAIL"}');
    print('=== END T1-1 ===\n');
  });
}
