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

/// EXP-CANCEL-T3-4: Liveness Probe Accuracy (Native)
///
/// N=1000 rapid spawn/terminate cycles with ACTIVE workloads.
/// Verifies isAlive returns true while running, false after terminate.
/// Success: 0 false positives, 0 false negatives, probe P95 < 500us.
void main() {
  final libPath = _resolveLibraryPath();

  var falsePositives = 0; // isAlive == true post-terminate
  var falseNegatives = 0; // isAlive == false while running
  final probeLatenciesUs = <int>[];
  const n = 1000;

  group('T3-4: liveness probe accuracy (N=$n)', () {
    for (var trial = 1; trial <= n; trial++) {
      test('trial $trial', () async {
        final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
        await isolate.init();

        // Start an ACTIVE workload so the handle stays alive.
        final startFuture = isolate.start(
          'while True: pass',
          externalFunctions: ['__never_called__'],
        );

        // Let the interpreter spin up.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        final hid = isolate.handleId;
        if (hid == null || hid <= 0) {
          unawaited(startFuture.then<void>((_) {}, onError: (_) {}));
          await isolate.terminate();
          return;
        }

        final token = MontyCancelToken(hid);

        // Pre-terminate: isAlive should be true (interpreter is running).
        if (!token.isAlive) {
          falseNegatives++;
        }

        // Measure probe latency.
        final sw = Stopwatch()..start();
        token.isAlive; // call
        sw.stop();
        probeLatenciesUs.add(sw.elapsedMicroseconds);

        // Terminate — cancel + cleanup.
        unawaited(startFuture.then<void>((_) {}, onError: (_) {}));
        await isolate.terminate();

        // Post-terminate: check at various delays.
        if (token.isAlive) falsePositives++;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (token.isAlive) falsePositives++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (token.isAlive) falsePositives++;
      });
    }
  });

  tearDownAll(() {
    probeLatenciesUs.sort();
    final p95Us = probeLatenciesUs.isNotEmpty
        ? probeLatenciesUs[(probeLatenciesUs.length * 0.95).floor()]
        : 0;

    print('\n=== EXP-CANCEL-T3-4 RESULTS ===');
    print('Trials: $n');
    print('False positives (isAlive==true post-terminate): $falsePositives');
    print('False negatives (isAlive==false while running): $falseNegatives');
    print('Probe latency P95: $p95Us us');
    print('');
    final pass = falsePositives == 0 && falseNegatives == 0 && p95Us < 500;
    print('VERDICT: ${pass ? "PASS" : "FAIL"}');
    print('  0 false positives: ${falsePositives == 0}');
    print('  0 false negatives: ${falseNegatives == 0}');
    print('  Probe P95 < 500us: ${p95Us < 500}');
    print('=== END T3-4 ===\n');
  });
}
