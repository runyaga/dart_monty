/// Web WASM example — run Python from Dart in the browser.
///
/// This is a standalone Dart script compiled to JS, not a package:test file.
/// It uses dart:js_interop directly to call the DartMontyBridge.
///
/// Build & run:
///   bash run.sh
library;

import 'dart:convert';
import 'dart:js_interop';

// JS interop bindings for window.DartMontyBridge
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

Map<String, dynamic> _parse(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

Future<void> main() async {
  print('=== dart_monty Web Example ===');
  print('');

  // Initialize the WASM Worker
  final ok = (await _bridgeInit().toDart).toDart;
  if (!ok) {
    print('ERROR: Failed to initialize Monty WASM Worker');
    print('EXAMPLE_DONE');
    return;
  }
  print('Worker initialized.');

  // ── 1. Simple expression ──────────────────────────────────────────────
  print('');
  print('── Simple expression ──');
  var r = _parse((await _bridgeRun('2 + 2'.toJS).toDart).toDart);
  print('  2 + 2 = ${r['value']}');

  // ── 2. Multi-line code ────────────────────────────────────────────────
  print('');
  print('── Multi-line code ──');
  r = _parse((await _bridgeRun('''
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a
fib(10)
'''
          .toJS)
      .toDart)
      .toDart);
  print('  fib(10) = ${r['value']}');

  // ── 3. String result ──────────────────────────────────────────────────
  print('');
  print('── String result ──');
  r = _parse((await _bridgeRun('"hello " * 3'.toJS).toDart).toDart);
  print('  "hello " * 3 = ${r['value']}');

  // ── 4. Error handling ─────────────────────────────────────────────────
  print('');
  print('── Error handling ──');
  r = _parse((await _bridgeRun('1 / 0'.toJS).toDart).toDart);
  print('  1/0 → error: ${r['error']}');

  // ── 5. Iterative execution ────────────────────────────────────────────
  print('');
  print('── Iterative execution ──');
  r = _parse(
    (await _bridgeStart(
      'fetch("https://example.com")'.toJS,
      '["fetch"]'.toJS,
    ).toDart)
        .toDart,
  );
  print('  start() → state=${r['state']}, fn=${r['functionName']}');

  r = _parse(
    (await _bridgeResume(jsonEncode('<html>Hello from Dart!</html>').toJS)
            .toDart)
        .toDart,
  );
  print('  resume() → state=${r['state']}, value=${r['value']}');

  // ── 6. Error injection ────────────────────────────────────────────────
  print('');
  print('── Error injection ──');
  r = _parse(
    (await _bridgeStart(
      '''
try:
    data = fetch("https://fail.example.com")
except Exception as e:
    result = f"caught: {e}"
result
'''
          .toJS,
      '["fetch"]'.toJS,
    ).toDart)
        .toDart,
  );
  print('  start() → state=${r['state']}');

  r = _parse(
    (await _bridgeResumeWithError(jsonEncode('network timeout').toJS).toDart)
        .toDart,
  );
  print('  resumeWithError() → value=${r['value']}');

  print('');
  print('=== All examples complete ===');
  print('EXAMPLE_DONE');
}
