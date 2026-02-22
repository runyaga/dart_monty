// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final monty = MontyPlatform.instance;

  // Run a simple Python expression.
  final result = await monty.run('2 + 2');
  print('Result: ${result.value}'); // 4

  // Run with resource limits.
  final limited = await monty.run(
    'sum(range(100))',
    limits: MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  print('Sum: ${limited.value}'); // 4950

  // Handle errors.
  final bad = await monty.run('1 / 0');
  if (bad.isError) {
    print('Error: ${bad.error!.message}');
  }

  await monty.dispose();
}
