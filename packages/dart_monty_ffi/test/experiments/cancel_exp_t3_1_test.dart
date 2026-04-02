@Tags(['integration'])
library;

// Experiment tests intentionally print results to stdout.
// ignore_for_file: avoid_print, lines_longer_than_80_chars, cascade_invocations

import 'dart:async';
import 'dart:math';

import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

/// EXP-CANCEL-T3-1: Cancellation Latency Profile (Native)
///
/// N=500 cancel latency measurements.
/// Success: P95 < 5ms, Max < 20ms.
void main() {
  final latenciesUs = <int>[]; // microseconds
  const n = 500;
  const warmup = 5;

  group('T3-1: cancel latency profile (N=$n)', () {
    // Warm-up trials (not measured).
    for (var i = 0; i < warmup; i++) {
      test('warmup $i', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();
        final f = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final sw = Stopwatch()..start();
        await isolate.cancel();
        try {
          await f;
        } on MontyCancelledError {
          // expected
        }
        sw.stop();
        // discard warmup
        await isolate.terminate();
      });
    }

    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl();
        await isolate.init();

        final startFuture = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        final sw = Stopwatch()..start();
        await isolate.cancel();
        try {
          await startFuture;
        } on MontyCancelledError {
          // expected
        }
        sw.stop();

        latenciesUs.add(sw.elapsedMicroseconds);

        await isolate.terminate();
      });
    }
  });

  tearDownAll(() {
    if (latenciesUs.isEmpty) return;

    latenciesUs.sort();
    final latenciesMs = latenciesUs.map((u) => u / 1000.0).toList();

    final median = latenciesMs[latenciesMs.length ~/ 2];
    final p95 = latenciesMs[(latenciesMs.length * 0.95).floor()];
    final p99 = latenciesMs[(latenciesMs.length * 0.99).floor()];
    final maxVal = latenciesMs.reduce(max);
    final mean = latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;

    // Bootstrap 95% CI for median (simple percentile bootstrap).
    final rng = Random(42);
    final bootstrapMedians = <double>[];
    for (var b = 0; b < 10000; b++) {
      final sample = List.generate(
        latenciesMs.length,
        (_) => latenciesMs[rng.nextInt(latenciesMs.length)],
      );
      sample.sort();
      bootstrapMedians.add(sample[sample.length ~/ 2]);
    }
    bootstrapMedians.sort();
    final ciLow = bootstrapMedians[(10000 * 0.025).floor()];
    final ciHigh = bootstrapMedians[(10000 * 0.975).floor()];

    print('\n=== EXP-CANCEL-T3-1 RESULTS ===');
    print('Trials: $n (+ $warmup warmup)');
    print('Cancel-to-catch latency (ms):');
    print('  Mean: ${mean.toStringAsFixed(3)}');
    print(
      '  Median: ${median.toStringAsFixed(3)} [95% CI: ${ciLow.toStringAsFixed(3)} - ${ciHigh.toStringAsFixed(3)}]',
    );
    print('  P95: ${p95.toStringAsFixed(3)}');
    print('  P99: ${p99.toStringAsFixed(3)}');
    print('  Max: ${maxVal.toStringAsFixed(3)}');
    print('');
    final pass = p95 < 5.0 && maxVal < 20.0;
    print('VERDICT: ${pass ? "PASS" : "FAIL"}');
    print('  P95 < 5ms: ${p95 < 5.0}');
    print('  Max < 20ms: ${maxVal < 20.0}');
    print('=== END T3-1 ===\n');
  });
}
