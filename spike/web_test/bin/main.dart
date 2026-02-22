/// M3B Web Viability Spike — Dart entry point.
///
/// Uses dart:js_interop to call into monty_glue.js bridge, which runs
/// @pydantic/monty WASM inside a Web Worker. Compiled to JS via
/// `dart compile js`.
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop bindings for window.montyBridge (Worker architecture)
// ---------------------------------------------------------------------------

@JS('montyBridge.init')
external JSPromise<JSBoolean> _montyInit();

@JS('montyBridge.run')
external JSPromise<JSString> _montyRun(JSString code);

@JS('montyBridge.start')
external JSPromise<JSString> _montyStart(JSString code, JSString extFnsJson);

@JS('montyBridge.resume')
external JSPromise<JSString> _montyResume(JSString valueJson);

@JS('montyBridge.discover')
external JSString _montyDiscover();

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parseResult(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void _printResult(String label, Map<String, dynamic> result) {
  if (result['ok'] == true) {
    print('  PASS $label => ${result['value'] ?? result['state']}');
  } else {
    print('  FAIL $label => ${result['errorType']}: ${result['error']}');
  }
}

// ---------------------------------------------------------------------------
// Spike test cases
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== M3B Web Viability Spike ===');
  print('');

  // Step 1: Discover API
  print('--- API Discovery ---');
  final discovery = _parseResult(_montyDiscover().toDart);
  print('  Architecture: ${discovery['architecture']}');
  print('');

  // Step 2: Initialize Monty Worker
  print('--- Initializing Monty Worker ---');
  final ok = (await _montyInit().toDart).toDart;
  print('  Init result: $ok');
  if (!ok) {
    print('');
    print('=== RESULT: NO-GO (init failed) ===');
    print('Monty WASM Worker could not be initialized.');
    return;
  }
  print('');

  // Step 3: Run test cases
  print('--- Test Case 1: run("2 + 2") ---');
  final r1 = _parseResult((await _montyRun('2 + 2'.toJS).toDart).toDart);
  _printResult('2 + 2', r1);

  print('--- Test Case 2: run(\'"hello " + "world"\') ---');
  final r2 =
      _parseResult((await _montyRun('"hello " + "world"'.toJS).toDart).toDart);
  _printResult('string concat', r2);

  print('--- Test Case 3: run("invalid syntax def") ---');
  final r3 =
      _parseResult((await _montyRun('invalid syntax def'.toJS).toDart).toDart);
  _printResult('syntax error', r3);

  // Step 4: Iterative execution (if API available)
  print('--- Test Case 4: start/resume (iterative) ---');
  try {
    final s1 = _parseResult(
      (await _montyStart(
        'result = fetch("https://example.com")'.toJS,
        '["fetch"]'.toJS,
      ).toDart)
          .toDart,
    );
    print('  start() => ${s1['state']}');

    if (s1['ok'] == true && s1['state'] == 'pending') {
      print('  functionName: ${s1['functionName']}');
      print('  args: ${s1['args']}');

      final s2 = _parseResult(
        (await _montyResume('"<html>mock response</html>"'.toJS).toDart).toDart,
      );
      print('  resume() => ${s2['state']}');
      if (s2['ok'] == true) {
        print('  value: ${s2['value']}');
      } else {
        print('  error: ${s2['error']}');
      }
    } else if (s1['ok'] == false) {
      print('  FAIL: ${s1['error']}');
    }
  } catch (e) {
    print('  Iterative API not available: $e');
  }

  print('');

  // Step 5: Verdict
  final allPassed = r1['ok'] == true && r2['ok'] == true && r3['ok'] == false;
  if (allPassed) {
    print('=== RESULT: GO ===');
    print('Dart -> JS interop -> @pydantic/monty WASM Worker works.');
  } else {
    print('=== RESULT: PARTIAL ===');
    print('Some tests passed, investigate failures above.');
  }
}
