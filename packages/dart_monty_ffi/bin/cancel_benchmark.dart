/// AOT-compatible cancel benchmark harness.
///
/// Runs T3-1 (cancel latency), T3-2 (terminate latency), and T3-4 (liveness)
/// experiments without the `test` package so it can be compiled with
/// `dart compile exe`.
///
/// Usage:
///   # JIT (baseline comparison):
///   DYLD_LIBRARY_PATH=../../native/target/release dart run bin/cancel_benchmark.dart
///
///   # AOT:
///   dart compile exe bin/cancel_benchmark.dart -o bin/cancel_benchmark
///   DYLD_LIBRARY_PATH=../../native/target/release ./bin/cancel_benchmark
library;

import 'dart:async';
import 'dart:io' show Platform, exit, stderr, stdout;
import 'dart:math';

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

String _resolveLibraryPath() {
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return '../../native/target/release/libdart_monty_native.$ext';
}

// ---------------------------------------------------------------------------
// T3-1: Cancel Latency
// ---------------------------------------------------------------------------
Future<Map<String, dynamic>> runT3_1({
  required String libPath,
  int n = 500,
  int warmup = 5,
}) async {
  final latenciesUs = <int>[];

  // Warmup
  for (var i = 0; i < warmup; i++) {
    final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
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
    final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
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
  required String libPath,
  int n = 500,
  int warmup = 5,
}) async {
  final latenciesUs = <int>[];

  for (var i = 0; i < warmup; i++) {
    final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
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
    final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
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
  required String libPath,
  int n = 1000,
}) async {
  var falsePositives = 0;
  var falseNegatives = 0;
  final probeLatenciesUs = <int>[];

  for (var trial = 1; trial <= n; trial++) {
    final isolate = NativeIsolateBindingsImpl(libraryPath: libPath);
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

  if (name == 'T3-4') {
    stdout.writeln('  Trials: ${r['n']}');
    stdout.writeln('  False positives: ${r['false_positives']}');
    stdout.writeln('  False negatives: ${r['false_negatives']}');
    stdout.writeln('  Probe P95: ${r['probe_p95_us']} us');
  } else {
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
  final libPath = _resolveLibraryPath();
  final isAot = const bool.fromEnvironment('dart.vm.product', defaultValue: false) ||
      !Platform.resolvedExecutable.endsWith('dart');
  final mode = isAot ? 'AOT' : 'JIT';

  stdout.writeln('=== Cancel Benchmark ($mode) ===');
  stdout.writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
  stdout.writeln('Dart: ${Platform.version}');
  stdout.writeln('Library: $libPath');
  stdout.writeln();

  final results = <Map<String, dynamic>>[];

  stdout.writeln('Running T3-1: Cancel Latency (N=500)...');
  results.add(await runT3_1(libPath: libPath));

  stdout.writeln('Running T3-2: Terminate Latency (N=500)...');
  results.add(await runT3_2(libPath: libPath));

  stdout.writeln('Running T3-4: Liveness Probe (N=1000)...');
  results.add(await runT3_4(libPath: libPath));

  stdout.writeln();
  stdout.writeln('=== RESULTS ($mode) ===');
  stdout.writeln();
  for (final r in results) {
    _printResult(r);
  }

  final allPass = results.every((r) => r['pass'] == true);
  stdout.writeln('OVERALL: ${allPass ? "PASS" : "FAIL"} ($mode)');

  exit(allPass ? 0 : 1);
}
