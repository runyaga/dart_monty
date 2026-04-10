import 'dart:convert';

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:monty_cli/src/output_formatter.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 1024,
    timeElapsedMs: 5,
    stackDepthUsed: 2,
  );

  group('format()', () {
    test('prints value', () {
      const result = MontyResult(value: MontyInt(42), usage: usage);
      expect(OutputFormatter.format(result), '42');
    });

    test('prints null value as empty', () {
      const result = MontyResult(usage: usage);
      expect(OutputFormatter.format(result), isEmpty);
    });

    test('prints error', () {
      const result = MontyResult(
        error: MontyException(message: 'name error'),
        usage: usage,
      );
      expect(OutputFormatter.format(result), 'Error: name error');
    });

    test('prints printOutput before value', () {
      const result = MontyResult(
        value: MontyString('done'),
        printOutput: 'hello world\n',
        usage: usage,
      );
      expect(OutputFormatter.format(result), 'hello world\ndone');
    });

    test('adds newline to printOutput if missing', () {
      const result = MontyResult(
        value: MontyInt(10),
        printOutput: 'debug',
        usage: usage,
      );
      expect(OutputFormatter.format(result), 'debug\n10');
    });
  });

  group('formatJson()', () {
    test('produces valid JSON', () {
      const result = MontyResult(value: MontyInt(42), usage: usage);
      final json = OutputFormatter.formatJson(result);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      expect(decoded['value'], 42);
      expect(decoded['usage'], isA<Map<String, dynamic>>());
    });
  });

  group('formatUsageStats()', () {
    test('includes tagged stats for stderr', () {
      const result = MontyResult(value: MontyInt(42), usage: usage);
      final output = OutputFormatter.formatUsageStats(result);
      expect(output, startsWith('[MONTY]'));
      expect(output, contains('memory=1024B'));
      expect(output, contains('time=5ms'));
      expect(output, contains('stack=2'));
    });
  });
}
