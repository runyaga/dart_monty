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
      buffer.write(result.value);
    }

    return buffer.toString();
  }

  /// Formats [result] as a JSON string.
  static String formatJson(MontyResult result) {
    return const JsonEncoder.withIndent('  ').convert(result.toJson());
  }

  /// Formats [result] with verbose resource usage stats.
  static String formatVerbose(MontyResult result) {
    final buffer = StringBuffer(format(result));
    final usage = result.usage;

    if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) {
      buffer.writeln();
    }
    buffer
      ..writeln('--- usage ---')
      ..writeln('memory: ${usage.memoryBytesUsed} bytes')
      ..writeln('time:   ${usage.timeElapsedMs} ms')
      ..write('stack:  ${usage.stackDepthUsed}');

    return buffer.toString();
  }
}
