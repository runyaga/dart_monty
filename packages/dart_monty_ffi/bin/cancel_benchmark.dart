/// AOT-compatible cancel benchmark harness.
///
/// Runs all cancel experiments (T1-1 through T3-4) without the `test` package
/// so it can be compiled with `dart compile exe`.
///
/// Usage:
///   # JIT (baseline comparison):
///   DYLD_LIBRARY_PATH=../../native/target/release dart run bin/cancel_benchmark.dart
///
///   # AOT:
///   dart compile exe bin/cancel_benchmark.dart -o bin/cancel_benchmark
///   DYLD_LIBRARY_PATH=../../native/target/release ./bin/cancel_benchmark
library;

// Benchmark harness — cascades harm readability in sequential stdout output.
// ignore_for_file: cascade_invocations

import 'dart:async';
import 'dart:io' show Platform, ProcessInfo, exit, stderr, stdout;
import 'dart:math';

import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// ---------------------------------------------------------------------------
// T1-1: Cancel Correctness & Idempotency
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT1_1({
  int cancelN = 200,
  int postCompleteN = 50,
}) async {
  var cancelledCount = 0;
  var wrongTypeCount = 0;
  var doubleThrowCount = 0;
  var postCompleteThrowCount = 0;

  for (var trial = 1; trial <= cancelN; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await isolate.cancel();
    try {
      await f;
      wrongTypeCount++;
    } on MontyCancelledError {
      cancelledCount++;
    } on Object {
      wrongTypeCount++;
    }
    try {
      await isolate.cancel();
    } on Object {
      doubleThrowCount++;
    }
    await isolate.terminate();
    if (trial % 50 == 0) stderr.write('\r  T1-1: $trial/$cancelN');
  }

  for (var trial = 1; trial <= postCompleteN; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    await isolate.run('2 + 2');
    try {
      await isolate.cancel();
    } on Object {
      postCompleteThrowCount++;
    }
    await isolate.dispose();
  }
  stderr.writeln();

  final pass =
      cancelledCount == cancelN &&
      wrongTypeCount == 0 &&
      doubleThrowCount == 0 &&
      postCompleteThrowCount == 0;

  return {
    'experiment': 'T1-1',
    'cancel_n': cancelN,
    'cancelled': cancelledCount,
    'wrong_type': wrongTypeCount,
    'double_throw': doubleThrowCount,
    'post_complete_throw': postCompleteThrowCount,
    'pass': pass,
  };
}

// ---------------------------------------------------------------------------
// T1-2: Cross-Boundary CancelToken Routing
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT1_2({
  int n = 100,
}) async {
  var crossCancelSuccess = 0;
  var stateErrorCount = 0;
  var isAlivePostTerminate = 0;

  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final hid = isolate.handleId;
    if (hid == null || hid <= 0) {
      unawaited(f.then<void>((_) {}, onError: (_) {}));
      await isolate.terminate();
      continue;
    }

    final token = MontyCancelToken(hid);
    final cancelled = token.cancel();
    if (!cancelled) stateErrorCount++;

    if (cancelled) {
      try {
        await f;
      } on MontyCancelledError {
        crossCancelSuccess++;
      } on Object {
        // wrong type
      }
    }

    await isolate.terminate();
    if (token.isAlive) isAlivePostTerminate++;
    if (trial % 20 == 0) stderr.write('\r  T1-2: $trial/$n');
  }
  stderr.writeln();

  return {
    'experiment': 'T1-2',
    'n': n,
    'cross_cancel_success': crossCancelSuccess,
    'state_error': stateErrorCount,
    'alive_post_terminate': isAlivePostTerminate,
    'pass':
        crossCancelSuccess == n &&
        stateErrorCount == 0 &&
        isAlivePostTerminate == 0,
  };
}

// ---------------------------------------------------------------------------
// T1-3: Terminate Resource Release
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT1_3({
  int n = 100,
}) async {
  var registryFreed = 0;
  var handleIdNulled = 0;

  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final hid = isolate.handleId;
    if (hid == null) {
      unawaited(f.then<void>((_) {}, onError: (_) {}));
      await isolate.terminate();
      continue;
    }

    unawaited(f.then<void>((_) {}, onError: (_) {}));
    await isolate.terminate();

    if (isolate.handleId == null) handleIdNulled++;
    final postState = NativeBindingsFfi.instanceOrNull?.isCancelledById(hid);
    if (postState == null) registryFreed++;

    if (trial % 20 == 0) stderr.write('\r  T1-3: $trial/$n');
  }
  stderr.writeln();

  return {
    'experiment': 'T1-3',
    'n': n,
    'registry_freed': registryFreed,
    'handle_id_nulled': handleIdNulled,
    'pass': registryFreed == n && handleIdNulled == n,
  };
}

// ---------------------------------------------------------------------------
// T1-4: Sealed Error Routing
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT1_4({
  int n = 50,
}) async {
  var subACorrect = 0;
  var subCCorrect = 0;
  var subDCorrect = 0;

  // Sub-A: Python exception → MontyException
  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    try {
      await isolate.run('1/0');
    } on MontyException catch (e) {
      if (e.excType == 'ZeroDivisionError') subACorrect++;
    } on Object {
      // wrong type
    }
    await isolate.dispose();
  }

  // Sub-C: Cancel → MontyCancelledError
  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await isolate.cancel();
    try {
      await f;
    } on MontyCancelledError {
      subCCorrect++;
    } on Object {
      // wrong type
    }
    await isolate.terminate();
  }

  // Sub-D: Terminate → error resolution
  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    Object? caughtError;
    unawaited(
      f.then<void>(
        (_) {},
        onError: (Object e) {
          caughtError = e;
        },
      ),
    );
    await isolate.terminate();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    if (caughtError is MontyDisposedError ||
        caughtError is MontyCancelledError ||
        caughtError is MontyCrashError) {
      subDCorrect++;
    }
    if (trial % 10 == 0) stderr.write('\r  T1-4: $trial/$n');
  }
  stderr.writeln();

  return {
    'experiment': 'T1-4',
    'n': n,
    'sub_a': subACorrect,
    'sub_c': subCCorrect,
    'sub_d': subDCorrect,
    'pass': subACorrect == n && subCCorrect == n && subDCorrect == n,
  };
}

// ---------------------------------------------------------------------------
// T2-2: Dispose Hang Prevention
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT2_2({
  int nC1 = 10,
  int nC2 = 50,
}) async {
  var c1Resolved = 0;
  var c1Hanging = 0;
  var c2Resolved = 0;
  var c2Hanging = 0;

  // C1: dispose() on stuck FFI (should work after #113 fix)
  for (var trial = 1; trial <= nC1; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final c = Completer<String>();
    unawaited(
      f.then<void>(
        (_) => c.complete('ok'),
        onError: (Object e) => c.complete(e.runtimeType.toString()),
      ),
    );

    try {
      await isolate.dispose().timeout(const Duration(seconds: 6));
    } on TimeoutException {
      await isolate.terminate();
    }

    final result = await c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'HANGING',
    );
    if (result == 'HANGING') {
      c1Hanging++;
    } else {
      c1Resolved++;
    }
    stderr.write('\r  T2-2 C1: $trial/$nC1');
  }
  stderr.writeln();

  // C2: terminate() (control)
  for (var trial = 1; trial <= nC2; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final c = Completer<String>();
    unawaited(
      f.then<void>(
        (_) => c.complete('ok'),
        onError: (Object e) => c.complete(e.runtimeType.toString()),
      ),
    );

    await isolate.terminate();

    final result = await c.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'HANGING',
    );
    if (result == 'HANGING') {
      c2Hanging++;
    } else {
      c2Resolved++;
    }
    if (trial % 10 == 0) stderr.write('\r  T2-2 C2: $trial/$nC2');
  }
  stderr.writeln();

  return {
    'experiment': 'T2-2',
    'c1_n': nC1,
    'c1_resolved': c1Resolved,
    'c1_hanging': c1Hanging,
    'c2_n': nC2,
    'c2_resolved': c2Resolved,
    'c2_hanging': c2Hanging,
    'pass': c1Hanging == 0 && c2Hanging == 0,
  };
}

// ---------------------------------------------------------------------------
// T2-3: Memory Soak
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT2_3({
  int totalCycles = 1000,
}) async {
  final checkpoints = [0, 100, 250, 500, 750, 1000];
  final rssAt = <int, int>{};

  // Warmup
  for (var i = 0; i < 5; i++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    await isolate.run('2 + 2');
    await isolate.dispose();
  }
  rssAt[0] = ProcessInfo.currentRss;

  for (var cycle = 1; cycle <= totalCycles; cycle++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    await isolate.run('2 + 2');
    await isolate.dispose();
    if (checkpoints.contains(cycle)) rssAt[cycle] = ProcessInfo.currentRss;
    if (cycle % 200 == 0) stderr.write('\r  T2-3: $cycle/$totalCycles');
  }
  stderr.writeln();

  final baseRss = rssAt[0] ?? 0;
  final finalRss = rssAt[totalCycles] ?? 0;
  final deltaMb = (finalRss - baseRss) / (1024 * 1024);

  // Linear regression
  final entries = rssAt.entries.where((e) => e.key > 0).toList();
  var slope = 0.0;
  if (entries.length >= 2) {
    final xs = entries.map((e) => e.key.toDouble()).toList();
    final ys = entries.map((e) => (e.value - baseRss) / (1024 * 1024)).toList();
    final nPts = xs.length;
    final mx = xs.reduce((a, b) => a + b) / nPts;
    final my = ys.reduce((a, b) => a + b) / nPts;
    var sxy = 0.0;
    var sx2 = 0.0;
    for (var i = 0; i < nPts; i++) {
      sxy += (xs[i] - mx) * (ys[i] - my);
      sx2 += (xs[i] - mx) * (xs[i] - mx);
    }
    slope = sx2 > 0 ? sxy / sx2 : 0;
  }

  return {
    'experiment': 'T2-3',
    'cycles': totalCycles,
    'delta_mb': deltaMb,
    'slope_mb_per_cycle': slope,
    'rss_checkpoints': rssAt.map(
      (k, v) => MapEntry(k, (v / (1024 * 1024)).toStringAsFixed(1)),
    ),
    'pass': deltaMb.abs() < 5.0 && slope.abs() < 0.005,
  };
}

// ---------------------------------------------------------------------------
// T3-1: Cancel Latency
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT3_1({
  int n = 500,
  int warmup = 5,
}) async {
  final latenciesUs = <int>[];

  // Warmup
  for (var i = 0; i < warmup; i++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await isolate.cancel();
    try {
      await f;
    } on MontyCancelledError {
      // expected
    }
    await isolate.terminate();
  }

  // Measured trials
  for (var trial = 1; trial <= n; trial++) {
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

    if (trial % 100 == 0) stderr.write('\r  T3-1: $trial/$n');
  }
  stderr.writeln();

  return _computeStats('T3-1', latenciesUs, n, warmup);
}

// ---------------------------------------------------------------------------
// T3-2: Terminate Latency
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT3_2({
  int n = 500,
  int warmup = 5,
}) async {
  final latenciesUs = <int>[];

  for (var i = 0; i < warmup; i++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final f = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    unawaited(f.then<void>((_) {}, onError: (_) {}));
    await isolate.terminate();
  }

  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final startFuture = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    unawaited(startFuture.then<void>((_) {}, onError: (_) {}));

    final sw = Stopwatch()..start();
    await isolate.terminate();
    sw.stop();

    latenciesUs.add(sw.elapsedMicroseconds);

    if (trial % 100 == 0) stderr.write('\r  T3-2: $trial/$n');
  }
  stderr.writeln();

  return _computeStats('T3-2', latenciesUs, n, warmup);
}

// ---------------------------------------------------------------------------
// T3-4: Liveness Probe Accuracy
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT3_4({
  int n = 1000,
}) async {
  var falsePositives = 0;
  var falseNegatives = 0;
  final probeLatenciesUs = <int>[];

  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl();
    await isolate.init();
    final startFuture = isolate.start(
      'while True: pass',
      externalFunctions: ['__never_called__'],
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final hid = isolate.handleId;
    if (hid == null || hid <= 0) {
      unawaited(startFuture.then<void>((_) {}, onError: (_) {}));
      await isolate.terminate();
      continue;
    }

    final token = MontyCancelToken(hid);

    if (!token.isAlive) falseNegatives++;

    final sw = Stopwatch()..start();
    token.isAlive;
    sw.stop();
    probeLatenciesUs.add(sw.elapsedMicroseconds);

    unawaited(startFuture.then<void>((_) {}, onError: (_) {}));
    await isolate.terminate();

    if (token.isAlive) falsePositives++;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (token.isAlive) falsePositives++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (token.isAlive) falsePositives++;

    if (trial % 200 == 0) stderr.write('\r  T3-4: $trial/$n');
  }
  stderr.writeln();

  probeLatenciesUs.sort();
  final p95Us = probeLatenciesUs.isNotEmpty
      ? probeLatenciesUs[(probeLatenciesUs.length * 0.95).floor()]
      : 0;

  final pass = falsePositives == 0 && falseNegatives == 0 && p95Us < 500;

  return {
    'experiment': 'T3-4',
    'n': n,
    'false_positives': falsePositives,
    'false_negatives': falseNegatives,
    'probe_p95_us': p95Us,
    'pass': pass,
  };
}

// ---------------------------------------------------------------------------
// Stats helpers
// ---------------------------------------------------------------------------
Map<String, dynamic> _computeStats(
  String name,
  List<int> latenciesUs,
  int n,
  int warmup,
) {
  latenciesUs.sort();
  final latenciesMs = latenciesUs.map((u) => u / 1000.0).toList();

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

  final pass = name == 'T3-1'
      ? (p95 < 5.0 && maxVal < 20.0)
      : (p95 < 20.0); // T3-2

  return {
    'experiment': name,
    'n': n,
    'warmup': warmup,
    'mean_ms': mean,
    'median_ms': median,
    'ci_low_ms': ciLow,
    'ci_high_ms': ciHigh,
    'p95_ms': p95,
    'p99_ms': p99,
    'max_ms': maxVal,
    'pass': pass,
  };
}

void _printResult(Map<String, dynamic> r) {
  final name = r['experiment'] as String;
  stdout.writeln('--- $name ---');

  switch (name) {
    case 'T1-1':
      stdout.writeln('  Cancel trials: ${r['cancel_n']}');
      stdout.writeln(
        '  MontyCancelledError: ${r['cancelled']} / ${r['cancel_n']}',
      );
      stdout.writeln('  Wrong type: ${r['wrong_type']}');
      stdout.writeln('  Double-cancel throws: ${r['double_throw']}');
      stdout.writeln('  Post-complete throws: ${r['post_complete_throw']}');
    case 'T1-2':
      stdout.writeln('  Trials: ${r['n']}');
      stdout.writeln(
        '  Cross-cancel success: ${r['cross_cancel_success']} / ${r['n']}',
      );
      stdout.writeln('  StateError: ${r['state_error']}');
      stdout.writeln('  Alive post-terminate: ${r['alive_post_terminate']}');
    case 'T1-3':
      stdout.writeln('  Trials: ${r['n']}');
      stdout.writeln('  Registry freed: ${r['registry_freed']} / ${r['n']}');
      stdout.writeln('  HandleId nulled: ${r['handle_id_nulled']} / ${r['n']}');
    case 'T1-4':
      stdout.writeln('  Trials per sub: ${r['n']}');
      stdout.writeln('  Sub-A (Python exc): ${r['sub_a']} / ${r['n']}');
      stdout.writeln('  Sub-C (Cancel): ${r['sub_c']} / ${r['n']}');
      stdout.writeln('  Sub-D (Dispose): ${r['sub_d']} / ${r['n']}');
    case 'T2-2':
      stdout.writeln(
        '  C1 dispose: ${r['c1_resolved']}/${r['c1_n']} resolved, ${r['c1_hanging']} hanging',
      );
      stdout.writeln(
        '  C2 terminate: ${r['c2_resolved']}/${r['c2_n']} resolved, ${r['c2_hanging']} hanging',
      );
    case 'T2-3':
      stdout.writeln('  Cycles: ${r['cycles']}');
      stdout.writeln(
        '  RSS delta: ${(r['delta_mb'] as double).toStringAsFixed(2)} MB',
      );
      stdout.writeln(
        '  Slope: ${(r['slope_mb_per_cycle'] as double).toStringAsFixed(6)} MB/cycle',
      );
    case 'T3-4':
      stdout.writeln('  Trials: ${r['n']}');
      stdout.writeln('  False positives: ${r['false_positives']}');
      stdout.writeln('  False negatives: ${r['false_negatives']}');
      stdout.writeln('  Probe P95: ${r['probe_p95_us']} us');
    default:
      // T3-1, T3-2 latency stats
      stdout.writeln('  Trials: ${r['n']} (+ ${r['warmup']} warmup)');
      stdout.writeln(
        '  Mean: ${(r['mean_ms'] as double).toStringAsFixed(3)} ms',
      );
      stdout.writeln(
        '  Median: ${(r['median_ms'] as double).toStringAsFixed(3)} ms '
        '[95% CI: ${(r['ci_low_ms'] as double).toStringAsFixed(3)} '
        '- ${(r['ci_high_ms'] as double).toStringAsFixed(3)}]',
      );
      stdout.writeln(
        '  P95: ${(r['p95_ms'] as double).toStringAsFixed(3)} ms',
      );
      stdout.writeln(
        '  P99: ${(r['p99_ms'] as double).toStringAsFixed(3)} ms',
      );
      stdout.writeln(
        '  Max: ${(r['max_ms'] as double).toStringAsFixed(3)} ms',
      );
  }
  stdout.writeln('  VERDICT: ${r['pass'] == true ? "PASS" : "FAIL"}');
  stdout.writeln();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
Future<void> main(List<String> args) async {
  final isAot =
      const bool.fromEnvironment('dart.vm.product') ||
      !Platform.resolvedExecutable.endsWith('dart');
  final mode = isAot ? 'AOT' : 'JIT';

  stdout
    ..writeln('=== Cancel Benchmark ($mode) ===')
    ..writeln(
      'Platform: ${Platform.operatingSystem} '
      '${Platform.operatingSystemVersion}',
    )
    ..writeln('Dart: ${Platform.version}')
    ..writeln();

  final results = <Map<String, dynamic>>[];

  stdout.writeln('Running T1-1: Cancel Correctness (N=200+50)...');
  results.add(await runT1_1());

  stdout.writeln('Running T1-2: CancelToken Routing (N=100)...');
  results.add(await runT1_2());

  stdout.writeln('Running T1-3: Terminate Resource Release (N=100)...');
  results.add(await runT1_3());

  stdout.writeln('Running T1-4: Sealed Error Routing (N=50x3)...');
  results.add(await runT1_4());

  stdout.writeln('Running T2-2: Dispose Hang Prevention (N=10+50)...');
  results.add(await runT2_2());

  stdout.writeln('Running T2-3: Memory Soak (N=1000)...');
  results.add(await runT2_3());

  stdout.writeln('Running T3-1: Cancel Latency (N=500)...');
  results.add(await runT3_1());

  stdout.writeln('Running T3-2: Terminate Latency (N=500)...');
  results.add(await runT3_2());

  stdout.writeln('Running T3-4: Liveness Probe (N=1000)...');
  results.add(await runT3_4());

  stdout
    ..writeln()
    ..writeln('=== RESULTS ($mode) ===')
    ..writeln();
  results.forEach(_printResult);

  final allPass = results.every((r) => r['pass'] == true);
  stdout.writeln('OVERALL: ${allPass ? "PASS" : "FAIL"} ($mode)');

  exit(allPass ? 0 : 1);
}
