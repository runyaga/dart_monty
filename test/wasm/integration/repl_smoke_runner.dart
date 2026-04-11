// Standalone JS-compiled runner, not a package:test file.
// ignore_for_file: avoid_print
/// Integration smoke test for dart_monty_wasm REPL support.
///
/// Compiled to JS, runs in headless Chrome with COOP/COEP headers.
///
/// Build:
///   dart compile js test/wasm/integration/repl_smoke_runner.dart \
///     -o test/wasm/integration/web/repl_smoke_runner.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop bindings for window.DartMontyBridge (REPL methods)
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.replCreate')
external JSPromise<JSString> _bridgeReplCreate();

@JS('DartMontyBridge.replFeedRun')
external JSPromise<JSString> _bridgeReplFeedRun(JSString code);

@JS('DartMontyBridge.replFree')
external JSPromise<JSString> _bridgeReplFree();

@JS('DartMontyBridge.replDetectContinuation')
external JSPromise<JSString> _bridgeReplDetectContinuation(JSString source);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _parse(String jsonStr) =>
    jsonDecode(jsonStr) as Map<String, dynamic>;

void _pass(String name) => print('SMOKE_PASS:$name');
void _fail(String name, String reason) => print('SMOKE_FAIL:$name:$reason');

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------

Future<void> _testReplVariablePersists() async {
  final create = _parse((await _bridgeReplCreate().toDart).toDart);
  if (create['ok'] != true) {
    _fail('repl_variable', 'Create failed: $create');
    return;
  }

  final r1 = _parse((await _bridgeReplFeedRun('x = 42'.toJS).toDart).toDart);
  if (r1['ok'] != true) {
    _fail('repl_variable', 'Feed x=42 failed: $r1');
    return;
  }

  final r2 = _parse((await _bridgeReplFeedRun('x + 1'.toJS).toDart).toDart);
  if (r2['ok'] == true && r2['value'] == 43) {
    _pass('repl_variable');
  } else {
    _fail('repl_variable', 'Expected 43, got ${r2['value']}');
  }

  await _bridgeReplFree().toDart;
}

Future<void> _testReplFunctionPersists() async {
  final create = _parse((await _bridgeReplCreate().toDart).toDart);
  if (create['ok'] != true) {
    _fail('repl_function', 'Create failed: $create');
    return;
  }

  await _bridgeReplFeedRun(
    'def greet(name):\n    return f"hello {name}"'.toJS,
  ).toDart;

  final r = _parse(
    (await _bridgeReplFeedRun('greet("world")'.toJS).toDart).toDart,
  );
  if (r['ok'] == true && r['value'] == 'hello world') {
    _pass('repl_function');
  } else {
    _fail('repl_function', 'Expected "hello world", got ${r['value']}');
  }

  await _bridgeReplFree().toDart;
}

Future<void> _testReplSurvivesError() async {
  final create = _parse((await _bridgeReplCreate().toDart).toDart);
  if (create['ok'] != true) {
    _fail('repl_survives_error', 'Create failed: $create');
    return;
  }

  await _bridgeReplFeedRun('x = 10'.toJS).toDart;

  // This should return an error but REPL survives.
  final errResult = _parse(
    (await _bridgeReplFeedRun('1 / 0'.toJS).toDart).toDart,
  );
  if (errResult['ok'] != false) {
    _fail('repl_survives_error', 'Expected error for 1/0, got ok');
    return;
  }

  // x should still be accessible.
  final r = _parse((await _bridgeReplFeedRun('x'.toJS).toDart).toDart);
  if (r['ok'] == true && r['value'] == 10) {
    _pass('repl_survives_error');
  } else {
    _fail('repl_survives_error', 'Expected 10, got ${r['value']}');
  }

  await _bridgeReplFree().toDart;
}

Future<void> _testReplDetectContinuation() async {
  final create = _parse((await _bridgeReplCreate().toDart).toDart);
  if (create['ok'] != true) {
    _fail('repl_continuation', 'Create failed: $create');
    return;
  }

  final complete = _parse(
    (await _bridgeReplDetectContinuation('x = 1'.toJS).toDart).toDart,
  );
  final block = _parse(
    (await _bridgeReplDetectContinuation('def f():'.toJS).toDart).toDart,
  );
  final implicit = _parse(
    (await _bridgeReplDetectContinuation('x = (1 +'.toJS).toDart).toDart,
  );

  if (complete['value'] == 0 && block['value'] == 2 && implicit['value'] == 1) {
    _pass('repl_continuation');
  } else {
    _fail(
      'repl_continuation',
      'complete=${complete['value']}, block=${block['value']}, '
          'implicit=${implicit['value']}',
    );
  }

  await _bridgeReplFree().toDart;
}

Future<void> _testRepl50Iterations() async {
  final create = _parse((await _bridgeReplCreate().toDart).toDart);
  if (create['ok'] != true) {
    _fail('repl_50_iterations', 'Create failed: $create');
    return;
  }

  await _bridgeReplFeedRun('total = 0'.toJS).toDart;
  for (var i = 1; i <= 50; i++) {
    await _bridgeReplFeedRun('total += $i'.toJS).toDart;
  }
  final r = _parse((await _bridgeReplFeedRun('total'.toJS).toDart).toDart);

  // sum of 1..50 = 1275
  if (r['ok'] == true && r['value'] == 1275) {
    _pass('repl_50_iterations');
  } else {
    _fail('repl_50_iterations', 'Expected 1275, got ${r['value']}');
  }

  await _bridgeReplFree().toDart;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== WASM REPL Smoke Tests ===');

  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    print('SMOKE_ERROR:Init failed');
    print('SMOKE_DONE');
    return;
  }

  await _testReplVariablePersists();
  await _testReplFunctionPersists();
  await _testReplSurvivesError();
  await _testReplDetectContinuation();
  await _testRepl50Iterations();

  print('SMOKE_DONE');
}
