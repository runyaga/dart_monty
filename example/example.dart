// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  // Run a simple Python expression.
  final result = await Monty.exec('2 + 2');
  print('Result: ${result.value}'); // 4

  // Run with resource limits.
  final limited = await Monty.exec(
    'sum(range(100))',
    limits: const MontyLimits(timeoutMs: 5000, memoryBytes: 10 * 1024 * 1024),
  );
  print('Sum: ${limited.value}'); // 4950

  // Handle errors.
  final bad = await Monty.exec('1 / 0');
  if (bad.isError) {
    print('Error: ${bad.error!.message}');
  }
}
