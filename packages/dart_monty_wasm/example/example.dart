// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';

/// Demonstrates the WASM-based API for running sandboxed Python in a browser.
///
/// Most apps should import `dart_monty` instead — the federated plugin
/// selects the correct backend automatically. Use this package directly
/// when building pure Dart web apps without Flutter.
///
/// Note: Futures support (resumeAsFuture/resolveFutures) is not available
/// on the WASM backend due to Web Worker limitations.
Future<void> main() async {
  final monty = MontyWasm(bindings: WasmBindingsJs());

  await _simpleRun(monty);
  await _runWithLimits(monty);
  await _externalFunctionDispatch(monty);
  await _errorHandling(monty);

  await monty.dispose();
}

/// Run a simple Python expression.
Future<void> _simpleRun(MontyWasm monty) async {
  final result = await monty.run('2 + 2');
  print('Simple: ${result.value}'); // 4
}

/// Run with resource limits.
Future<void> _runWithLimits(MontyWasm monty) async {
  final result = await monty.run(
    'sum(range(100))',
    limits: const MontyLimits(
      timeoutMs: 5000,
      memoryBytes: 10 * 1024 * 1024,
    ),
  );
  print('With limits: ${result.value}'); // 4950
}

/// Use start/resume to handle external function calls from Python.
Future<void> _externalFunctionDispatch(MontyWasm monty) async {
  var progress = await monty.start(
    'fetch("https://api.example.com/data")',
    externalFunctions: ['fetch'],
  );

  while (progress is MontyPending) {
    print('Python called: ${progress.functionName}(${progress.arguments})');
    progress = await monty.resume({'status': 'ok'});
  }

  final complete = progress as MontyComplete;
  print('Dispatch result: ${complete.result.value}');
}

/// Catch Python errors.
Future<void> _errorHandling(MontyWasm monty) async {
  try {
    await monty.run('1 / 0');
  } on MontyException catch (e) {
    print('Exception type: ${e.excType}'); // ZeroDivisionError
    print('Message: ${e.message}');
  }
}
