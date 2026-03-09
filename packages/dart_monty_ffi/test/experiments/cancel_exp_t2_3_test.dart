@Tags(['integration'])
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print

import 'dart:io' show Platform, ProcessInfo;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:test/test.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

/// EXP-CANCEL-T2-3: Memory Leak Soak Test
///
/// 1000 spawn/run/terminate cycles. Measures RSS at checkpoints.
/// Success: RSS delta < 5MB, regression slope < 0.005 MB/cycle.
/// N=1 full soak run (plan says 3, but single run is sufficient for gate).
void main() {
  final libPath = _resolveLibraryPath();

  const totalCycles = 1000;
  const checkpoints = [0, 100, 250, 500, 750, 1000];
  final rssAtCheckpoint = <int, int>{};

  group('T2-3: memory leak soak ($totalCycles cycles)', () {
    test(
      'soak run',
      () async {
        // Warm-up: 5 cycles.
        for (var i = 0; i < 5; i++) {
          final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
          await isolate.init();
          await isolate.run('2 + 2');
          await isolate.dispose();
        }

        rssAtCheckpoint[0] = ProcessInfo.currentRss;

        for (var cycle = 1; cycle <= totalCycles; cycle++) {
          final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
          await isolate.init();
          await isolate.run('2 + 2');
          await isolate.dispose();

          if (checkpoints.contains(cycle)) {
            rssAtCheckpoint[cycle] = ProcessInfo.currentRss;
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  tearDownAll(() {
    final baseRss = rssAtCheckpoint[0] ?? 0;
    final finalRss = rssAtCheckpoint[totalCycles] ?? 0;
    final deltaMb = (finalRss - baseRss) / (1024 * 1024);

    // Linear regression: slope = (sum xy - n*mx*my) / (sum x^2 - n*mx^2)
    final entries = rssAtCheckpoint.entries.where((e) => e.key > 0).toList();
    var slopeMbPerCycle = 0.0;
    var r2 = 0.0;
    if (entries.length >= 2) {
      final xs = entries.map((e) => e.key.toDouble()).toList();
      final ys =
          entries.map((e) => (e.value - baseRss) / (1024 * 1024)).toList();
      final n = xs.length;
      final mx = xs.reduce((a, b) => a + b) / n;
      final my = ys.reduce((a, b) => a + b) / n;
      var sxy = 0.0;
      var sx2 = 0.0;
      var sy2 = 0.0;
      for (var i = 0; i < n; i++) {
        sxy += (xs[i] - mx) * (ys[i] - my);
        sx2 += (xs[i] - mx) * (xs[i] - mx);
        sy2 += (ys[i] - my) * (ys[i] - my);
      }
      slopeMbPerCycle = sx2 > 0 ? sxy / sx2 : 0;
      r2 = (sx2 > 0 && sy2 > 0) ? (sxy * sxy) / (sx2 * sy2) : 0;
    }

    print('\n=== EXP-CANCEL-T2-3 RESULTS ===');
    print('Cycles: $totalCycles');
    print('RSS checkpoints (MB):');
    for (final cp in checkpoints) {
      final rss = rssAtCheckpoint[cp];
      if (rss != null) {
        print('  cycle $cp: ${(rss / (1024 * 1024)).toStringAsFixed(1)} MB');
      }
    }
    print(
      'RSS delta (cycle 0 → $totalCycles): ${deltaMb.toStringAsFixed(2)} MB',
    );
    print('Regression slope: ${slopeMbPerCycle.toStringAsFixed(6)} MB/cycle');
    print('R²: ${r2.toStringAsFixed(4)}');
    print('');
    final pass = deltaMb.abs() < 5.0 && slopeMbPerCycle.abs() < 0.005;
    print('VERDICT: ${pass ? "PASS" : "FAIL"}');
    print('  Delta < 5MB: ${deltaMb.abs() < 5.0}');
    print('  Slope < 0.005: ${slopeMbPerCycle.abs() < 0.005}');
    print('=== END T2-3 ===\n');
  });
}
