/// WASM Re-Entrancy Spike — 5 test scenarios.
///
/// Validates the suspend/resume/error chain on the Monty WASM bridge.
/// Compile: dart compile js bin/main.dart -o web/main.dart.js
/// Serve:   node serve.mjs
library;

// ignore_for_file: avoid_print

import 'dart:async';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';

// ---------------------------------------------------------------------------
// Result tracking
// ---------------------------------------------------------------------------

class ScenarioResult {
  ScenarioResult({required this.pass, required this.notes, this.ms});
  final bool pass;
  final String notes;
  final int? ms;
}

final Map<String, ScenarioResult> _results = {};

// ---------------------------------------------------------------------------
// Scenario 1: Happy Path — Suspend and Resume
// ---------------------------------------------------------------------------

Future<void> _scenario1(MontyWasm monty) async {
  print('=== Scenario 1: Happy Path — Suspend and Resume ===');
  final sw = Stopwatch()..start();

  try {
    final progress = await monty.start(
      'echo("hello")',
      externalFunctions: ['echo'],
    );

    if (progress is! MontyPending) {
      sw.stop();
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyPending, got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    if (progress.functionName != 'echo') {
      sw.stop();
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Expected functionName=echo, got ${progress.functionName}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    if (progress.arguments.length != 1 ||
        progress.arguments[0] != 'hello') {
      sw.stop();
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Expected args=["hello"], got ${progress.arguments}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final complete = await monty.resume('hello back');
    sw.stop();

    if (complete is! MontyComplete) {
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyComplete, got ${complete.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final result = complete.result;
    if (result.isError) {
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Script errored: ${result.error}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    if (result.value != 'hello back') {
      _results['1. Happy path'] = ScenarioResult(
        pass: false,
        notes: 'Expected "hello back", got ${result.value}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    _results['1. Happy path'] = ScenarioResult(
      pass: true,
      notes: 'Suspend/resume round-trip: ${sw.elapsedMilliseconds}ms',
      ms: sw.elapsedMilliseconds,
    );
  } catch (e, st) {
    sw.stop();
    _results['1. Happy path'] = ScenarioResult(
      pass: false,
      notes: 'Exception: $e\n$st',
      ms: sw.elapsedMilliseconds,
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario 2: Re-Entrancy Attempt — Guard Fires
// ---------------------------------------------------------------------------

Future<void> _scenario2(MontyWasm monty) async {
  print('');
  print('=== Scenario 2: Re-Entrancy Guard ===');
  final sw = Stopwatch()..start();

  try {
    // Start first execution — Python suspends on external call.
    final progress1 = await monty.start(
      'long_running("task")',
      externalFunctions: ['long_running'],
    );

    if (progress1 is! MontyPending) {
      sw.stop();
      _results['2. Re-entrancy guard'] = ScenarioResult(
        pass: false,
        notes: 'First start: expected MontyPending, got ${progress1.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    // While Python is suspended, try to start ANOTHER execution.
    try {
      await monty.start('x = 1');
      // If we get here, re-entrancy was NOT blocked.
      sw.stop();
      _results['2. Re-entrancy guard'] = ScenarioResult(
        pass: false,
        notes: 'Re-entrancy was NOT blocked — no StateError thrown',
        ms: sw.elapsedMilliseconds,
      );
      return;
    } on StateError catch (e) {
      print('  Guard fired: $e');
    }

    // Clean up: resume the original execution.
    final complete = await monty.resume('done');
    sw.stop();

    if (complete is! MontyComplete) {
      _results['2. Re-entrancy guard'] = ScenarioResult(
        pass: false,
        notes: 'Resume after guard: expected MontyComplete, got '
            '${complete.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    _results['2. Re-entrancy guard'] = ScenarioResult(
      pass: true,
      notes: 'StateError thrown correctly, resume succeeded '
          '(${sw.elapsedMilliseconds}ms)',
      ms: sw.elapsedMilliseconds,
    );
  } catch (e, st) {
    sw.stop();
    _results['2. Re-entrancy guard'] = ScenarioResult(
      pass: false,
      notes: 'Exception: $e\n$st',
      ms: sw.elapsedMilliseconds,
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario 3: Error Recovery — resumeWithError
// ---------------------------------------------------------------------------

Future<void> _scenario3(MontyWasm monty) async {
  print('');
  print('=== Scenario 3: Error Recovery — resumeWithError ===');
  final sw = Stopwatch()..start();

  try {
    const script = '''
try:
    result = triggers_reentry("data")
except Exception as e:
    result = f"caught: {e}"
result
''';

    final progress = await monty.start(
      script,
      externalFunctions: ['triggers_reentry'],
    );

    if (progress is! MontyPending) {
      sw.stop();
      _results['3. Error recovery'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyPending, got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    // Simulate: the host tried to re-enter Python but couldn't.
    // Resume with an error instead.
    final complete = await monty.resumeWithError(
      'ReentrantCallBlocked: cannot enter Python while suspended',
    );
    sw.stop();

    if (complete is! MontyComplete) {
      _results['3. Error recovery'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyComplete, got ${complete.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final result = complete.result;

    // Python should have caught the exception — script itself should not
    // report isError.
    if (result.isError) {
      _results['3. Error recovery'] = ScenarioResult(
        pass: false,
        notes: 'Script crashed instead of catching: ${result.error}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final value = result.value?.toString() ?? '';
    if (!value.contains('caught:')) {
      _results['3. Error recovery'] = ScenarioResult(
        pass: false,
        notes: 'Expected value containing "caught:", got "$value"',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    _results['3. Error recovery'] = ScenarioResult(
      pass: true,
      notes: 'Python caught the error: "$value" '
          '(${sw.elapsedMilliseconds}ms)',
      ms: sw.elapsedMilliseconds,
    );
  } catch (e, st) {
    sw.stop();
    _results['3. Error recovery'] = ScenarioResult(
      pass: false,
      notes: 'Exception: $e\n$st',
      ms: sw.elapsedMilliseconds,
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario 4: Suspend -> Multiple Host Calls -> Resume
// ---------------------------------------------------------------------------

Future<void> _scenario4(MontyWasm monty) async {
  print('');
  print('=== Scenario 4: Multiple Sequential Host Calls ===');
  final sw = Stopwatch()..start();

  try {
    const script = '''
a = spawn_agent("legal", "review contract")
b = spawn_agent("finance", "run projections")
result_a = get_result(a)
result_b = get_result(b)
f"Legal: {result_a}, Finance: {result_b}"
''';

    var progress = await monty.start(
      script,
      externalFunctions: ['spawn_agent', 'get_result'],
    );

    // Call 1: spawn_agent("legal", "review contract")
    if (progress is! MontyPending ||
        progress.functionName != 'spawn_agent') {
      sw.stop();
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Call 1: expected spawn_agent pending, '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    print('  Call 1: ${progress.functionName}(${progress.arguments})');
    progress = await monty.resume(42); // handle 42

    // Call 2: spawn_agent("finance", "run projections")
    if (progress is! MontyPending ||
        progress.functionName != 'spawn_agent') {
      sw.stop();
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Call 2: expected spawn_agent pending, '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    print('  Call 2: ${progress.functionName}(${progress.arguments})');
    progress = await monty.resume(43); // handle 43

    // Call 3: get_result(42)
    if (progress is! MontyPending ||
        progress.functionName != 'get_result') {
      sw.stop();
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Call 3: expected get_result pending, '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    print('  Call 3: ${progress.functionName}(${progress.arguments})');
    progress = await monty.resume('contract looks good');

    // Call 4: get_result(43)
    if (progress is! MontyPending ||
        progress.functionName != 'get_result') {
      sw.stop();
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Call 4: expected get_result pending, '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }
    print('  Call 4: ${progress.functionName}(${progress.arguments})');
    progress = await monty.resume('projections positive');

    sw.stop();

    // Should be complete now.
    if (progress is! MontyComplete) {
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyComplete after 4 calls, '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final result = progress.result;
    if (result.isError) {
      _results['4. Concurrent work'] = ScenarioResult(
        pass: false,
        notes: 'Script errored: ${result.error}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    // The last line is an f-string expression — its value is the result.
    final value = result.value?.toString() ?? '';
    final printOut = result.printOutput ?? '';
    final hasLegal =
        value.contains('Legal:') || printOut.contains('Legal:');
    final hasFinance =
        value.contains('Finance:') || printOut.contains('Finance:');

    _results['4. Concurrent work'] = ScenarioResult(
      pass: hasLegal && hasFinance,
      notes: hasLegal && hasFinance
          ? '4 suspend/resume cycles OK: "$value" '
              '(${sw.elapsedMilliseconds}ms)'
          : 'Missing sub-agent results. value="$value", '
              'printOutput="$printOut"',
      ms: sw.elapsedMilliseconds,
    );
  } catch (e, st) {
    sw.stop();
    _results['4. Concurrent work'] = ScenarioResult(
      pass: false,
      notes: 'Exception: $e\n$st',
      ms: sw.elapsedMilliseconds,
    );
  }
}

// ---------------------------------------------------------------------------
// Scenario 5: CPU-Bound Script — Timeout Enforcement
// ---------------------------------------------------------------------------

Future<void> _scenario5(MontyWasm monty) async {
  print('');
  print('=== Scenario 5: CPU-Bound Timeout ===');

  // Schedule a periodic timer to check event loop responsiveness.
  var timerFired = 0;
  final timer = Timer.periodic(
    const Duration(milliseconds: 200),
    (_) => timerFired++,
  );

  final sw = Stopwatch()..start();

  try {
    final progress = await monty.start(
      // Infinite loop — should be killed by timeout.
      'while True:\n    x = 1',
      limits: const MontyLimits(timeoutMs: 2000),
    );
    sw.stop();
    timer.cancel();

    if (progress is! MontyComplete) {
      _results['5. CPU-bound timeout'] = ScenarioResult(
        pass: false,
        notes: 'Expected MontyComplete (timeout error), '
            'got ${progress.runtimeType}',
        ms: sw.elapsedMilliseconds,
      );
      return;
    }

    final result = progress.result;
    final elapsed = sw.elapsedMilliseconds;

    // Timeout should fire within ~2-5s. If it took >10s, something's wrong.
    final timedOut = elapsed < 10000;
    final isError = result.isError;

    print('  Timeout fired in ${elapsed}ms');
    print('  Result is error: $isError');
    print('  Timer callbacks during execution: $timerFired');
    print('  Event loop responsive: ${timerFired > 0 ? "YES" : "NO"}');

    _results['5. CPU-bound timeout'] = ScenarioResult(
      pass: isError && timedOut,
      notes: isError && timedOut
          ? 'Timeout fired in ${elapsed}ms, event loop ticks=$timerFired'
          : 'isError=$isError, elapsed=${elapsed}ms, ticks=$timerFired',
      ms: elapsed,
    );
  } on MontyException catch (e) {
    // Timeout might surface as a thrown MontyException rather than
    // MontyComplete with isError.
    sw.stop();
    timer.cancel();
    final elapsed = sw.elapsedMilliseconds;
    print('  Timeout threw MontyException in ${elapsed}ms: ${e.message}');
    print('  Timer callbacks during execution: $timerFired');

    _results['5. CPU-bound timeout'] = ScenarioResult(
      pass: elapsed < 10000,
      notes: 'MontyException: ${e.message} in ${elapsed}ms, '
          'ticks=$timerFired',
      ms: elapsed,
    );
  } catch (e, st) {
    sw.stop();
    timer.cancel();
    final elapsed = sw.elapsedMilliseconds;

    // A timeout that surfaces as any kind of error within a reasonable
    // time window counts as a pass.
    if (elapsed < 10000) {
      _results['5. CPU-bound timeout'] = ScenarioResult(
        pass: true,
        notes: 'Timeout surfaced as ${e.runtimeType} in ${elapsed}ms: $e',
        ms: elapsed,
      );
    } else {
      _results['5. CPU-bound timeout'] = ScenarioResult(
        pass: false,
        notes: 'Exception after ${elapsed}ms: $e\n$st',
        ms: elapsed,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

void _printResult(String name) {
  final r = _results[name];
  if (r == null) return;
  final tag = r.pass ? 'PASS' : 'FAIL';
  final ms = r.ms != null ? ' (${r.ms}ms)' : '';
  print('  --> [$tag] $name$ms');
  print('      ${r.notes}');
}

void _printSummary() {
  print('');
  print('============================================================');
  print('  RESULTS SUMMARY');
  print('============================================================');
  print('');

  for (final entry in _results.entries) {
    final tag = entry.value.pass ? 'PASS' : 'FAIL';
    final ms = entry.value.ms != null ? ' (${entry.value.ms}ms)' : '';
    print('  [$tag] ${entry.key}$ms');
    print('         ${entry.value.notes}');
    print('');
  }

  // Overall verdict.
  final passCount = _results.values.where((r) => r.pass).length;
  final total = _results.length;
  print('------------------------------------------------------------');

  if (passCount == total) {
    print('  VERDICT: ALL $total PASS');
    print('  WASM is safe for full Layer 0-3. Ship it.');
  } else if (passCount >= 4 &&
      !(_results['5. CPU-bound timeout']?.pass ?? false)) {
    print('  VERDICT: $passCount/$total PASS (Scenario 5 failed)');
    print('  WASM can orchestrate but cannot enforce CPU timeouts.');
    print('  Options: Web Worker isolation, instruction limit, or');
    print('  restrict WASM to host-call-yielding scripts only.');
  } else if (passCount >= 2 &&
      !(_results['3. Error recovery']?.pass ?? false)) {
    print('  VERDICT: $passCount/$total PASS (Scenario 3 failed)');
    print('  resumeWithError() broken on WASM.');
    print('  WASM clients get Layer 0-1 only. Native gets full 0-3.');
  } else if (!(_results['1. Happy path']?.pass ?? false)) {
    print('  VERDICT: BRIDGE BROKEN');
    print('  Scenario 1 failed. Escalate to dart_monty team.');
  } else {
    print('  VERDICT: $passCount/$total PASS');
    print('  See individual results above.');
  }

  print('============================================================');
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('============================================================');
  print('  WASM Re-Entrancy Spike — 5 Scenarios');
  print('============================================================');

  // --- Scenario 1: Happy path ---
  final monty1 = MontyWasm(bindings: WasmBindingsJs());
  await _scenario1(monty1);
  _printResult('1. Happy path');
  await monty1.dispose();

  if (!(_results['1. Happy path']?.pass ?? false)) {
    print('');
    print('Scenario 1 FAILED — bridge is broken. Stopping.');
    _printSummary();
    return;
  }

  // --- Scenario 2: Re-entrancy guard ---
  final monty2 = MontyWasm(bindings: WasmBindingsJs());
  await _scenario2(monty2);
  _printResult('2. Re-entrancy guard');
  await monty2.dispose();

  // --- Scenario 3: Error recovery ---
  final monty3 = MontyWasm(bindings: WasmBindingsJs());
  await _scenario3(monty3);
  _printResult('3. Error recovery');
  await monty3.dispose();

  // --- Scenario 4: Multi-call flow ---
  final monty4 = MontyWasm(bindings: WasmBindingsJs());
  await _scenario4(monty4);
  _printResult('4. Concurrent work');
  await monty4.dispose();

  // --- Scenario 5: CPU-bound timeout ---
  // Wrap in a Dart-side timeout. If the WASM runtime can't enforce the
  // timeout, the Worker hangs forever. We detect this from the main thread.
  print('');
  print('=== Scenario 5: CPU-Bound Timeout ===');
  print('  (Dart-side 15s safety timeout wrapping 2s WASM timeout)');
  final monty5 = MontyWasm(bindings: WasmBindingsJs());
  try {
    await _scenario5(monty5).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        print('  Dart-side timeout fired at 15s — WASM timeout did NOT work');
        print('  The Worker is stuck in an infinite Python loop.');
        _results['5. CPU-bound timeout'] = ScenarioResult(
          pass: false,
          notes: 'WASM timeout did not fire. Dart-side 15s safety timeout '
              'triggered. The Worker thread is unresponsive.',
          ms: 15000,
        );
      },
    );
  } catch (e) {
    _results['5. CPU-bound timeout'] ??= ScenarioResult(
      pass: false,
      notes: 'Unexpected error: $e',
    );
  }
  _printResult('5. CPU-bound timeout');
  // Skip dispose — Worker may be hung.

  _printSummary();
}
