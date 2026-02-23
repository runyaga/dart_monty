// Printing to stdout is expected in an example.
// ignore_for_file: avoid_print
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Demonstrates the platform interface types.
///
/// This package defines the abstract contract — use `dart_monty` for a
/// concrete implementation.
void main() {
  // Construct a result from JSON (as returned by native/web backends).
  final result = MontyResult.fromJson(const {
    'value': 42,
    'usage': {
      'memory_bytes_used': 1024,
      'time_elapsed_ms': 5,
      'stack_depth_used': 2,
    },
  });

  print('Value: ${result.value}');
  print('Memory: ${result.usage.memoryBytesUsed} bytes');
  print('Time: ${result.usage.timeElapsedMs} ms');

  // Construct limits.
  const limits = MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
  );
  print('Timeout: ${limits.timeoutMs} ms');
}
