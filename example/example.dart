// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final monty = Monty();

  // Run a simple Python expression.
  final result = await monty.run('2 + 2');
  print('Result: ${result.value}'); // 4

  // Run with resource limits.
  final limited = await monty.run(
    'sum(range(100))',
    limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  print('Sum: ${limited.value}'); // 4950

  // Handle errors — run() throws MontyScriptError for Python exceptions.
  try {
    await monty.run('1 / 0');
  } on MontyScriptError catch (e) {
    print('Python ${e.excType}: ${e.message}');
  }

  await monty.dispose();
}
