@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

/// EXP-CANCEL-T3-2: Terminate Cycle Latency (Native)
///
/// N=500 full terminate() latency measurements.
/// Success: P95 < 20ms.
void main() {
  final libPath = _resolveLibraryPath();

  final terminateLatenciesUs = <int>[];
  const n = 500;
  const warmup = 5;

  group('T3-2: terminate cycle latency (N=$n)', () {
    for (var i = 0; i < warmup; i++) {
      test('warmup $i', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();
        final f = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // discard warmup timing
        unawaited(f.then<void>((_) {}, onError: (_) {}));
        await isolate.terminate();
      });
    }

    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        final startFuture = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );

        await Future<void>.delayed(const Duration(milliseconds: 100));

        // Guard the Future so its error doesn't escape the zone.
        unawaited(
          startFuture.then<void>((_) {}, onError: (_) {}),
        );

        final sw = Stopwatch()..start();
        await isolate.terminate();
        sw.stop();

        terminateLatenciesUs.add(sw.elapsedMicroseconds);
      });
    }
  });

  tearDownAll(() {
    if (terminateLatenciesUs.isEmpty) return;

    terminateLatenciesUs.sort();
    final latenciesMs =
        terminateLatenciesUs.map((u) => u / 1000.0).toList();

    final median = latenciesMs[latenciesMs.length ~/ 2];
    final p95 = latenciesMs[(latenciesMs.length * 0.95).floor()];
    final p99 = latenciesMs[(latenciesMs.length * 0.99).floor()];
    final maxVal = latenciesMs.reduce(max);
    final mean = latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;

    // Bootstrap 95% CI for median.
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

    print('\n=== EXP-CANCEL-T3-2 RESULTS ===');
    print('Trials: $n (+ $warmup warmup)');
    print('Terminate latency (ms):');
    print('  Mean: ${mean.toStringAsFixed(3)}');
    print('  Median: ${median.toStringAsFixed(3)} [95% CI: ${ciLow.toStringAsFixed(3)} - ${ciHigh.toStringAsFixed(3)}]');
    print('  P95: ${p95.toStringAsFixed(3)}');
    print('  P99: ${p99.toStringAsFixed(3)}');
    print('  Max: ${maxVal.toStringAsFixed(3)}');
    print('');
    final pass = p95 < 20.0;
    print('VERDICT: ${pass ? "PASS" : "FAIL"}');
    print('  P95 < 20ms: ${p95 < 20.0}');
    print('=== END T3-2 ===\n');
  });
}
