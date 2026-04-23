// Standalone WASM fuzz harness for dart_monty (high-level runtime)
// Reads Python code from window.location.hash (base64 encoded).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty_bridge.dart';

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

  final runtime = MontyRuntime();
  
  // Register exactly like the CLI harness
  runtime.register(HostFunction(
    schema: const HostFunctionSchema(name: 'host_sync_get_counter'),
    handler: (args, _) async => 0,
  ));
  
  runtime.register(HostFunction(
    schema: const HostFunctionSchema(name: 'host_async_delay'),
    handler: (args, _) async {
      final ms = args['ms'] as int? ?? 10;
      await Future.delayed(Duration(milliseconds: ms));
      return 'slept_$ms';
    },
  ));

  try {
    if (code.contains('# --- MONTY_SESSION_STEP ---')) {
      final steps = code.split('# --- MONTY_SESSION_STEP ---');
      var stepIdx = 0;
      for (var stepCode in steps) {
        final step = stepCode.trim();
        if (step.isEmpty) continue;
        final res = await runtime.execute(step).result;
        if (res.error != null) {
           print('FUZZ_RESULT:{"isError":true,"step":$stepIdx,"error":"${res.error!.message}"}');
           return;
        }
        stepIdx++;
      }
      print('FUZZ_RESULT:{"isError":false,"value":"session_completed"}');
    } else {
      final res = await runtime.execute(code).result;
      final output = {
        'isError': res.isError,
        'value': res.value.dartValue,
        if (res.error != null) 'error': res.error!.message,
        if (res.error != null) 'excType': res.error!.excType,
        'printOutput': res.printOutput,
      };
      print('FUZZ_RESULT:${json.encode(output)}');
    }
  } catch (e) {
    print('FUZZ_RESULT:{"isError":true,"error":"$e"}');
  } finally {
    await runtime.dispose();
    print('FUZZ_DONE');
  }
}
