/// WASM Cancel Benchmark — compiled to JS, runs in headless Chrome.
///
/// Uses DartMontyBridge.init() + start() for the default session,
/// then _benchFastCancel(sessionId) to immediately terminate the Worker.
///
/// Build:
///   dart compile js test/integration/cancel_benchmark.dart \
///     -o test/integration/web/cancel_benchmark.dart.js
library;

import 'dart:async';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop — default session API + fast cancel helper
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _init();

@JS('DartMontyBridge.start')
external JSPromise<JSString> _start(JSString code, [JSString? extFnsJson]);

@JS('DartMontyBridge.run')
external JSPromise<JSString> _run(JSString code);

@JS('_benchFastCancel')
external void _fastCancel(JSNumber sessionId);

@JS('DartMontyBridge.getDefaultSessionId')
external JSNumber? _getDefaultSessionId();

@JS('performance.now')
external double _perfNow();

void _log(String msg) => _consoleLog(msg.toJS);

@JS('console.log')
external void _consoleLog(JSString msg);

// ---------------------------------------------------------------------------
// T1-1W: Cancel Correctness (Web/WASM)
// ---------------------------------------------------------------------------

Future<void> runT1_1W({int n = 50}) async {
  _log('BENCH_START:T1-1W Cancel Correctness (N=$n)');

  var resolvedCount = 0;
  var timeoutCount = 0;
  var resolvedTypes = <String, int>{};

  for (var trial = 1; trial <= n; trial++) {
    // init() creates a fresh default session (or reuses existing).
    final ok = (await _init().toDart).toDart;
    if (!ok) {
      _log('BENCH_WARN:T1-1W trial $trial init failed');
      continue;
    }
    final sid = _getDefaultSessionId();
    if (sid == null) {
      _log('BENCH_WARN:T1-1W trial $trial no session ID');
      continue;
    }

    // Start infinite loop on default session.
    final startCompleter = Completer<String>();
    _start('while True: pass'.toJS).toDart.then(
          (result) => startCompleter.complete('OK:${result.toDart}'),
          onError: (Object e) => startCompleter.complete('ERR:$e'),
        );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Fast cancel — immediately terminates Worker and rejects pending.
    _fastCancel(sid);

    final result = await startCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'TIMEOUT',
    );

    if (result == 'TIMEOUT') {
      timeoutCount++;
    } else {
      resolvedCount++;
      final key = result.contains('disposed')
          ? 'Session disposed'
          : result.contains('crashed')
              ? 'Worker crashed'
              : result.length > 50
                  ? '${result.substring(0, 50)}...'
                  : result;
      resolvedTypes[key] = (resolvedTypes[key] ?? 0) + 1;
    }
  }

  _log('BENCH_RESULT:T1-1W');
  _log('BENCH_DATA:  Trials: $n');
  _log('BENCH_DATA:  Resolved: $resolvedCount / $n');
  _log('BENCH_DATA:  Timeout: $timeoutCount');
  _log('BENCH_DATA:  Types: $resolvedTypes');
  final pass = resolvedCount == n && timeoutCount == 0;
  _log('BENCH_VERDICT:T1-1W ${pass ? "PASS" : "FAIL"}');
}

// ---------------------------------------------------------------------------
// T1-4W: Sealed Error Routing (Web/WASM)
// ---------------------------------------------------------------------------

Future<void> runT1_4W({int n = 50}) async {
  _log('BENCH_START:T1-4W Sealed Error Routing (N=$n)');

  var subACorrect = 0; // Python exception
  var subCCorrect = 0; // Cancel → Session disposed
  var subAWrong = 0;
  var subCWrong = 0;

  // Sub-A: Python exception → error in JSON result
  for (var trial = 1; trial <= n; trial++) {
    final ok = (await _init().toDart).toDart;
    if (!ok) continue;

    final resultJson = (await _run('1/0'.toJS).toDart).toDart;
    if (resultJson.contains('ZeroDivisionError') ||
        resultJson.contains('division by zero')) {
      subACorrect++;
    } else {
      subAWrong++;
    }
    // Dispose session for next trial.
    final sid = _getDefaultSessionId();
    if (sid != null) _fastCancel(sid);
  }

  // Sub-C: Cancel → Session disposed error
  for (var trial = 1; trial <= n; trial++) {
    final ok = (await _init().toDart).toDart;
    if (!ok) continue;
    final sid = _getDefaultSessionId();
    if (sid == null) continue;

    final startCompleter = Completer<String>();
    _start('while True: pass'.toJS).toDart.then(
          (result) => startCompleter.complete('OK:${result.toDart}'),
          onError: (Object e) => startCompleter.complete('ERR:$e'),
        );

    await Future<void>.delayed(const Duration(milliseconds: 100));
    _fastCancel(sid);

    final result = await startCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'TIMEOUT',
    );

    if (result.contains('disposed') || result.contains('crashed')) {
      subCCorrect++;
    } else {
      subCWrong++;
    }
  }

  _log('BENCH_RESULT:T1-4W');
  _log('BENCH_DATA:  Sub-A (Python exc): $subACorrect / $n');
  _log('BENCH_DATA:  Sub-C (Cancel): $subCCorrect / $n');
  final pass = subACorrect == n && subCCorrect == n;
  _log('BENCH_VERDICT:T1-4W ${pass ? "PASS" : "FAIL"}');
}

// ---------------------------------------------------------------------------
// T2-2W: Dispose Future Resolution (Web/WASM)
// ---------------------------------------------------------------------------

Future<void> runT2_2W({int n = 20}) async {
  _log('BENCH_START:T2-2W Dispose Future Resolution (N=$n)');

  var resolvedCount = 0;
  var timeoutCount = 0;

  for (var trial = 1; trial <= n; trial++) {
    final ok = (await _init().toDart).toDart;
    if (!ok) continue;
    final sid = _getDefaultSessionId();
    if (sid == null) continue;

    final startCompleter = Completer<String>();
    _start('while True: pass'.toJS).toDart.then(
          (result) => startCompleter.complete('OK:${result.toDart}'),
          onError: (Object e) => startCompleter.complete('ERR:$e'),
        );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Use disposeSession (via _fastCancel) — should reject all pending
    // promises and resolve the start() Future.
    _fastCancel(sid);

    final result = await startCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 'TIMEOUT',
    );

    if (result == 'TIMEOUT') {
      timeoutCount++;
    } else {
      resolvedCount++;
    }
  }

  _log('BENCH_RESULT:T2-2W');
  _log('BENCH_DATA:  Resolved: $resolvedCount / $n');
  _log('BENCH_DATA:  Timeout: $timeoutCount');
  final pass = resolvedCount == n && timeoutCount == 0;
  _log('BENCH_VERDICT:T2-2W ${pass ? "PASS" : "FAIL"}');
}

// ---------------------------------------------------------------------------
// T3-1W: Cancel Latency
// ---------------------------------------------------------------------------

Future<void> runT3_1W({int n = 100, int warmup = 5}) async {
  _log('BENCH_START:T3-1W Cancel Latency (N=$n)');

  final latencies = <double>[];

  for (var trial = 1; trial <= warmup + n; trial++) {
    final ok = (await _init().toDart).toDart;
    if (!ok) continue;
    final sid = _getDefaultSessionId();
    if (sid == null) continue;

    final startCompleter = Completer<void>();
    _start('while True: pass'.toJS).toDart.then(
          (_) => startCompleter.complete(),
          onError: (_) => startCompleter.complete(),
        );

    await Future<void>.delayed(const Duration(milliseconds: 100));

    final t0 = _perfNow();
    _fastCancel(sid);
    await startCompleter.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    final t1 = _perfNow();

    if (trial > warmup) {
      latencies.add(t1 - t0);
    }
  }

  _printLatencyResults('T3-1W', latencies, n, warmup);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

void _printLatencyResults(
  String name,
  List<double> latencies,
  int n,
  int warmup,
) {
  if (latencies.isEmpty) {
    _log('BENCH_ERROR:$name No successful trials');
    return;
  }

  latencies.sort();
  final median = latencies[latencies.length ~/ 2];
  final p95 = latencies[(latencies.length * 0.95).floor()];
  final p99 = latencies[(latencies.length * 0.99).floor()];
  final maxVal = latencies.last;
  final mean = latencies.reduce((a, b) => a + b) / latencies.length;

  _log('BENCH_RESULT:$name');
  _log('BENCH_DATA:  Trials: ${latencies.length} / $n (+ $warmup warmup)');
  _log('BENCH_DATA:  Mean: ${mean.toStringAsFixed(3)} ms');
  _log('BENCH_DATA:  Median: ${median.toStringAsFixed(3)} ms');
  _log('BENCH_DATA:  P95: ${p95.toStringAsFixed(3)} ms');
  _log('BENCH_DATA:  P99: ${p99.toStringAsFixed(3)} ms');
  _log('BENCH_DATA:  Max: ${maxVal.toStringAsFixed(3)} ms');

  final pass = p95 < 5.0 && maxVal < 20.0;
  _log('BENCH_VERDICT:$name ${pass ? "PASS" : "FAIL"}');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  _log('BENCH_HEADER:=== WASM Cancel Benchmark ===');

  await runT1_1W();
  await runT1_4W();
  await runT2_2W();
  await runT3_1W();

  // N/A experiments (documented):
  // T1-2W: N/A — no handleId/MontyCancelToken in WASM (no out-of-band cancel API)
  // T1-3W: N/A — cannot probe Rust registry from browser (no isCancelledById)
  // T2-3W: N/A — browser memory API (performance.memory) is deprecated/unreliable
  // T3-2W: N/A — Worker.terminate() IS the cancel mechanism (no separate terminate path)
  // T3-4W: N/A — no MontyCancelToken/liveness probe API in WASM
  _log('BENCH_NA:T1-2W No handleId/MontyCancelToken in WASM');
  _log('BENCH_NA:T1-3W Cannot probe Rust registry from browser');
  _log('BENCH_NA:T2-3W Browser memory API unreliable');
  _log('BENCH_NA:T3-2W Worker.terminate() IS the cancel mechanism');
  _log('BENCH_NA:T3-4W No liveness probe API in WASM');

  _log('BENCH_DONE');
}
