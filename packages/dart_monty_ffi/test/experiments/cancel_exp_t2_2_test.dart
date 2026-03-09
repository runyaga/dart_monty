@Tags(['integration'])
@Timeout(Duration(minutes: 10))
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print, lines_longer_than_80_chars

import 'dart:async';
import 'dart:io' show Platform;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:test/test.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

/// EXP-CANCEL-T2-2: Future Hang Prevention
///
/// Tests whether ALL terminal paths guarantee Dart Future resolution.
///
/// Scenario C (native): dispose() during run → start() Future must resolve.
///   - C1: dispose() alone (no cancel) — known to hang (measures hang)
///   - C2: terminate() — expected to work (control group)
///
/// N=50 per scenario.
void main() {
  final libPath = _resolveLibraryPath();

  // --- Scenario C1 metrics: dispose() without cancel ---
  var c1ResolvedCount = 0;
  var c1HangingCount = 0;
  var c1DisposeHangCount = 0;
  final c1ResolvedTypes = <String, int>{};
  final c1ResolutionTimesMs = <double>[];

  // --- Scenario C2 metrics: terminate() ---
  var c2ResolvedCount = 0;
  var c2HangingCount = 0;
  final c2ResolvedTypes = <String, int>{};
  final c2ResolutionTimesMs = <double>[];

  const nC1 = 10; // dispose() hang is deterministic — 10 sufficient
  const nC2 = 50;
  const disposeTimeoutMs = 6000; // 6s — if dispose doesn't return, it's hung
  const futureHangTimeoutMs = 5000; // 5s after dispose attempt

  // =========================================================================
  // Scenario C1: dispose() without cancel() on stuck FFI
  // =========================================================================
  group('T2-2-C1: dispose() during run (N=$nC1)', () {
    for (var trial = 1; trial <= nC1; trial++) {
      test(
        'trial $trial',
        () async {
          final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
          await isolate.init();

          final startFuture = isolate.start(
            'while True: pass',
            externalFunctions: ['__never_called__'],
          );

          await Future<void>.delayed(const Duration(milliseconds: 100));

          final sw = Stopwatch()..start();

          // Track whether startFuture resolves.
          final futureCompleter = Completer<String>();
          unawaited(
            startFuture.then<void>(
              (_) {
                sw.stop();
                futureCompleter.complete('completed_normally');
              },
              onError: (Object e) {
                sw.stop();
                futureCompleter.complete(e.runtimeType.toString());
              },
            ),
          );

          // Try dispose() with a timeout — it may hang because worker
          // is stuck in FFI and can't process the _DisposeRequest.
          var disposeHung = false;
          try {
            await isolate.dispose().timeout(
                  const Duration(milliseconds: disposeTimeoutMs),
                );
          } on TimeoutException {
            disposeHung = true;
            c1DisposeHangCount++;
          }

          // Check if startFuture resolved (give it a short window).
          final result = await futureCompleter.future.timeout(
            const Duration(milliseconds: futureHangTimeoutMs),
            onTimeout: () => 'HANGING',
          );

          if (result == 'HANGING') {
            c1HangingCount++;
          } else {
            c1ResolvedCount++;
            c1ResolutionTimesMs.add(sw.elapsedMicroseconds / 1000.0);
            c1ResolvedTypes[result] = (c1ResolvedTypes[result] ?? 0) + 1;
          }

          // Force-clean with terminate() so we don't leak zombies between trials.
          if (disposeHung) {
            await isolate.terminate();
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  });

  // =========================================================================
  // Scenario C2: terminate() during run (control — expected to work)
  // =========================================================================
  group('T2-2-C2: terminate() during run (N=$nC2)', () {
    for (var trial = 1; trial <= nC2; trial++) {
      test(
        'trial $trial',
        () async {
          final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
          await isolate.init();

          final startFuture = isolate.start(
            'while True: pass',
            externalFunctions: ['__never_called__'],
          );

          await Future<void>.delayed(const Duration(milliseconds: 100));

          final sw = Stopwatch()..start();

          final futureCompleter = Completer<String>();
          unawaited(
            startFuture.then<void>(
              (_) {
                sw.stop();
                futureCompleter.complete('completed_normally');
              },
              onError: (Object e) {
                sw.stop();
                futureCompleter.complete(e.runtimeType.toString());
              },
            ),
          );

          await isolate.terminate();

          final result = await futureCompleter.future.timeout(
            const Duration(milliseconds: futureHangTimeoutMs),
            onTimeout: () => 'HANGING',
          );

          if (result == 'HANGING') {
            c2HangingCount++;
          } else {
            c2ResolvedCount++;
            c2ResolutionTimesMs.add(sw.elapsedMicroseconds / 1000.0);
            c2ResolvedTypes[result] = (c2ResolvedTypes[result] ?? 0) + 1;
          }
        },
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  });

  // =========================================================================
  // Summary
  // =========================================================================
  tearDownAll(() {
    String stats(List<double> times) {
      if (times.isEmpty) return 'N/A';
      times.sort();
      final median = times[times.length ~/ 2];
      final p95 = times[(times.length * 0.95).floor()];
      final max = times.last;
      return 'median=${median.toStringAsFixed(2)}ms '
          'P95=${p95.toStringAsFixed(2)}ms '
          'max=${max.toStringAsFixed(2)}ms';
    }

    print('\n=== EXP-CANCEL-T2-2 RESULTS ===');
    print('');
    print('--- Scenario C1: dispose() without cancel (N=$nC1) ---');
    print('  Future resolved: $c1ResolvedCount / $nC1');
    print('  Future hanging:  $c1HangingCount / $nC1');
    print('  dispose() hung:  $c1DisposeHangCount / $nC1');
    print('  Resolution types: $c1ResolvedTypes');
    print('  Resolution time: ${stats(c1ResolutionTimesMs)}');
    print('');
    print('--- Scenario C2: terminate() (N=$nC2) ---');
    print('  Future resolved: $c2ResolvedCount / $nC2');
    print('  Future hanging:  $c2HangingCount / $nC2');
    print('  Resolution types: $c2ResolvedTypes');
    print('  Resolution time: ${stats(c2ResolutionTimesMs)}');
    print('');

    final c1Pass = c1HangingCount == 0;
    final c2Pass = c2HangingCount == 0;
    print('VERDICT C1 (dispose): ${c1Pass ? "PASS" : "FAIL"}'
        '${!c1Pass ? " — $c1HangingCount/$nC1 futures hung, $c1DisposeHangCount/$nC1 dispose() calls hung" : ""}');
    print('VERDICT C2 (terminate): ${c2Pass ? "PASS" : "FAIL"}'
        '${!c2Pass ? " — $c2HangingCount/$nC2 futures hung" : ""}');
    print('');
    print('OVERALL: ${c1Pass && c2Pass ? "PASS" : "FAIL"}');
    print('=== END T2-2 ===\n');
  });
}
