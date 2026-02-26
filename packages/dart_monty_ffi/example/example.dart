// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Demonstrates the native FFI API for running sandboxed Python.
///
/// Most apps should import `dart_monty` instead — the federated plugin
/// selects the correct backend automatically. Use this package directly
/// for CLI tools, server-side Dart, or when you need fine-grained control.
Future<void> main() async {
  final monty = MontyFfi(bindings: NativeBindingsFfi());

  await _simpleRun(monty);
  await _runWithLimits(monty);
  await _externalFunctionDispatch(monty);
  await _errorHandling(monty);
  await _printCapture(monty);
  await _snapshotRestore(monty);

  await monty.dispose();
}

/// Run a simple Python expression and read the result.
Future<void> _simpleRun(MontyFfi monty) async {
  final result = await monty.run('2 + 2');
  print('Simple: ${result.value}'); // 4
}

/// Run with resource limits (timeout, memory, stack depth).
Future<void> _runWithLimits(MontyFfi monty) async {
  final result = await monty.run(
    'sum(range(100))',
    limits: const MontyLimits(
      timeoutMs: 5000,
      memoryBytes: 10 * 1024 * 1024,
      stackDepth: 100,
    ),
  );
  print('With limits: ${result.value}'); // 4950
  print('Memory used: ${result.usage.memoryBytesUsed} bytes');
  print('Time elapsed: ${result.usage.timeElapsedMs} ms');
}

/// Use start/resume to handle external function calls from Python.
Future<void> _externalFunctionDispatch(MontyFfi monty) async {
  // Python calls fetch(), which pauses execution and returns to Dart.
  var progress = await monty.start(
    'fetch("https://api.example.com/data")',
    externalFunctions: ['fetch'],
  );

  // Dispatch loop — handle each external call until execution completes.
  while (progress is MontyPending) {
    print('Python called: ${progress.functionName}(${progress.arguments})');

    // Provide the return value back to Python.
    progress = await monty.resume({
      'users': ['alice', 'bob'],
    });
  }

  final complete = progress as MontyComplete;
  print('Dispatch result: ${complete.result.value}');
}

/// Catch Python errors with full exception details.
Future<void> _errorHandling(MontyFfi monty) async {
  try {
    await monty.run('1 / 0');
  } on MontyException catch (e) {
    print('Exception type: ${e.excType}'); // ZeroDivisionError
    print('Message: ${e.message}');
  }
}

/// Capture Python print() output.
Future<void> _printCapture(MontyFfi monty) async {
  final result = await monty.run('print("hello from Python")');
  print('Print output: ${result.printOutput}'); // hello from Python
}

/// Save and restore interpreter state via snapshots.
///
/// Snapshots capture state mid-execution (during a start/resume loop).
Future<void> _snapshotRestore(MontyFfi monty) async {
  // Start execution that pauses on an external function call.
  await monty.start(
    'x = 42\nget_value()',
    externalFunctions: ['get_value'],
  );
  // Interpreter is now paused — snapshot the in-progress state.
  final bytes = await monty.snapshot();
  print('Snapshot size: ${bytes.length} bytes');

  // Resume the original to completion.
  await monty.resume(99);

  // Restore the snapshot into a fresh instance — it resumes from the pause.
  final restored = await monty.restore(bytes) as MontyFfi;
  final restoredProgress = await restored.resume(100);
  final complete = restoredProgress as MontyComplete;
  print('Restored result: ${complete.result.value}'); // 100

  await restored.dispose();
}
