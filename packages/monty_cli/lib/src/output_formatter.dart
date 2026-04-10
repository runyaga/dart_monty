import 'dart:convert';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Formats a [MontyResult] for terminal output.
abstract final class OutputFormatter {
  /// Formats [result] as a human-readable string.
  static String format(MontyResult result) {
    final buffer = StringBuffer();

    if (result.printOutput case final output?) {
      buffer.write(output);
      if (!output.endsWith('\n')) buffer.writeln();
    }

    if (result.isError) {
      final error = result.error!;
      buffer.write('Error: ${error.message}');
    } else if (result.value != null) {
      buffer.write(result.value!.dartValue);
    }

    return buffer.toString();
  }

  /// Formats [result] as a JSON string.
  static String formatJson(MontyResult result) {
    return const JsonEncoder.withIndent('  ').convert(result.toJson());
  }

  /// Formats resource usage stats for stderr output.
  static String formatUsageStats(MontyResult result) {
    final usage = result.usage;

    return '[MONTY] memory=${usage.memoryBytesUsed}B '
        'time=${usage.timeElapsedMs}ms '
        'stack=${usage.stackDepthUsed}';
  }
}
