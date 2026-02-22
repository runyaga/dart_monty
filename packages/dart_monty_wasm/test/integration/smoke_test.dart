/// Integration smoke test for dart_monty_wasm.
///
/// Compiled to JS, runs in headless Chrome with COOP/COEP headers.
/// This is a standalone executable, not a package:test file.
///
/// Build:
///   dart compile js test/integration/smoke_test.dart \
///     -o test/integration/web/smoke_test.dart.js
library;

import 'dart:convert';
import 'dart:js_interop';

// ---------------------------------------------------------------------------
// JS interop bindings for window.DartMontyBridge
// ---------------------------------------------------------------------------

@JS('DartMontyBridge.init')
external JSPromise<JSBoolean> _bridgeInit();

@JS('DartMontyBridge.run')
external JSPromise<JSString> _bridgeRun(JSString code, [JSString? limitsJson]);

@JS('DartMontyBridge.start')
external JSPromise<JSString> _bridgeStart(
  JSString code, [
  JSString? extFnsJson,
  JSString? limitsJson,
]);

@JS('DartMontyBridge.resume')
external JSPromise<JSString> _bridgeResume(JSString valueJson);

@JS('DartMontyBridge.resumeWithError')
external JSPromise<JSString> _bridgeResumeWithError(JSString errorJson);

@JS('DartMontyBridge.snapshot')
external JSPromise<JSString> _bridgeSnapshot();

@JS('DartMontyBridge.restore')
external JSPromise<JSString> _bridgeRestore(JSString dataBase64);

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

Future<void> _testSimpleRun() async {
  final result = _parse((await _bridgeRun('2 + 2'.toJS).toDart).toDart);
  if (result['ok'] == true && result['value'] == 4) {
    _pass('simple_run');
  } else {
    _fail('simple_run', 'Expected 4, got ${result['value']}');
  }
}

Future<void> _testStringResult() async {
  final result = _parse((await _bridgeRun('"hello world"'.toJS).toDart).toDart);
  if (result['ok'] == true && result['value'] == 'hello world') {
    _pass('string_result');
  } else {
    _fail('string_result', 'Expected "hello world", got ${result['value']}');
  }
}

Future<void> _testErrorHandling() async {
  final result = _parse((await _bridgeRun('1/0'.toJS).toDart).toDart);
  if (result['ok'] == false && result['error'] != null) {
    _pass('error_handling');
  } else {
    _fail('error_handling', 'Expected error, got ok=${result['ok']}');
  }
}

Future<void> _testIterative() async {
  final startResult = _parse(
    (await _bridgeStart(
      'fetch("url")'.toJS,
      '["fetch"]'.toJS,
    ).toDart)
        .toDart,
  );

  if (startResult['ok'] != true || startResult['state'] != 'pending') {
    _fail('iterative', 'Expected pending, got $startResult');
    return;
  }

  if (startResult['functionName'] != 'fetch') {
    _fail(
      'iterative',
      'Expected functionName=fetch, got ${startResult['functionName']}',
    );
    return;
  }

  final resumeResult = _parse(
    (await _bridgeResume(jsonEncode('response_data').toJS).toDart).toDart,
  );

  if (resumeResult['ok'] == true && resumeResult['state'] == 'complete') {
    _pass('iterative');
  } else {
    _fail('iterative', 'Expected complete, got $resumeResult');
  }
}

Future<void> _testResumeWithError() async {
  // Code that calls an external function and catches the error
  const code = '''
try:
    fetch("url")
except Exception as e:
    result = str(e)
result
''';

  final startResult = _parse(
    (await _bridgeStart(code.toJS, '["fetch"]'.toJS).toDart).toDart,
  );

  if (startResult['ok'] != true || startResult['state'] != 'pending') {
    _fail('resume_with_error', 'Expected pending, got $startResult');
    return;
  }

  final errorJson = jsonEncode('network failure');
  final resumeResult = _parse(
    (await _bridgeResumeWithError(errorJson.toJS).toDart).toDart,
  );

  if (resumeResult['ok'] == true && resumeResult['state'] == 'complete') {
    _pass('resume_with_error');
  } else {
    _fail('resume_with_error', 'Expected complete, got $resumeResult');
  }
}

Future<void> _testSnapshot() async {
  // Start an iterative execution
  final startResult = _parse(
    (await _bridgeStart(
      'fetch("url")'.toJS,
      '["fetch"]'.toJS,
    ).toDart)
        .toDart,
  );

  if (startResult['ok'] != true || startResult['state'] != 'pending') {
    _fail('snapshot', 'Start: expected pending, got $startResult');
    return;
  }

  // Take a snapshot
  final snapResult = _parse((await _bridgeSnapshot().toDart).toDart);

  if (snapResult['ok'] != true || snapResult['data'] == null) {
    // MontySnapshot.dump() uses Node.js Buffer, not available in browsers.
    // This is a known NAPI-RS limitation — skip gracefully.
    final error = snapResult['error'] as String? ?? '';
    if (error.contains('Buffer')) {
      _pass('snapshot_skip_buffer');
      return;
    }
    _fail('snapshot', 'Snapshot failed: $snapResult');
    return;
  }

  // Restore the snapshot
  final restoreResult = _parse(
    (await _bridgeRestore((snapResult['data'] as String).toJS).toDart).toDart,
  );

  if (restoreResult['ok'] == true) {
    _pass('snapshot');
  } else {
    _fail('snapshot', 'Restore failed: $restoreResult');
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

Future<void> main() async {
  print('=== WASM Smoke Tests ===');

  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    print('SMOKE_ERROR:Init failed');
    print('SMOKE_DONE');
    return;
  }

  await _testSimpleRun();
  await _testStringResult();
  await _testErrorHandling();
  await _testIterative();
  await _testResumeWithError();
  await _testSnapshot();

  print('SMOKE_DONE');
}
