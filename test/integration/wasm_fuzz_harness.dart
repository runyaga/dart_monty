// Standalone WASM fuzz harness for headless-Chrome CLI.
//
// Compile with:
//   dart compile js test/integration/wasm_fuzz_harness.dart \
//     -o test/integration/web/wasm_fuzz_harness.dart.js
//
// Reads Python code from window.location.hash (base64 encoded),
// runs it through MontyWasm, and prints the result as JSON.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty_core/dart_monty_core.dart';

@JS('window.location.hash')
external JSString get _windowHash;

Future<void> main() async {
  final hash = _windowHash.toDart;
  if (hash.isEmpty || !hash.startsWith('#')) {
    print('FUZZ_RESULT:{"isError":true,"error":"No code provided in hash"}');
    return;
  }

  final base64Code = hash.substring(1);
  String code;
  try {
    code = utf8.decode(base64.decode(base64Code));
  } catch (e) {
    print('FUZZ_RESULT:{"isError":true,"error":"Invalid base64 code: $e"}');
    return;
  }

  final platform = createPlatformMonty();
  try {
    final result = await platform.run(code);
    
    final output = {
      'isError': result.isError,
      'value': result.value.dartValue,
      if (result.error != null) 'error': result.error!.message,
      if (result.error != null) 'excType': result.error!.excType,
      'printOutput': result.printOutput,
    };
    
    print('FUZZ_RESULT:${json.encode(output)}');
  } catch (e) {
    print('FUZZ_RESULT:{"isError":true,"error":"$e"}');
  } finally {
    await platform.dispose();
    print('FUZZ_DONE');
  }
}
