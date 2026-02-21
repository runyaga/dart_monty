import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MontyResourceUsage', () {
    test('constructs with all fields', () {
      const usage = MontyResourceUsage(
        memoryBytesUsed: 1024,
        timeElapsedMs: 50,
        stackDepthUsed: 10,
      );
      expect(usage.memoryBytesUsed, 1024);
      expect(usage.timeElapsedMs, 50);
      expect(usage.stackDepthUsed, 10);
    });

    test('handles zero values', () {
      const usage = MontyResourceUsage(
        memoryBytesUsed: 0,
        timeElapsedMs: 0,
        stackDepthUsed: 0,
      );
      expect(usage.memoryBytesUsed, 0);
      expect(usage.timeElapsedMs, 0);
      expect(usage.stackDepthUsed, 0);
    });

    test('handles large values', () {
      const usage = MontyResourceUsage(
        memoryBytesUsed: 1073741824, // 1 GB
        timeElapsedMs: 3600000, // 1 hour
        stackDepthUsed: 10000,
      );
      expect(usage.memoryBytesUsed, 1073741824);
      expect(usage.timeElapsedMs, 3600000);
      expect(usage.stackDepthUsed, 10000);
    });

    group('fromJson', () {
      test('parses JSON', () {
        final usage = MontyResourceUsage.fromJson(const {
          'memory_bytes_used': 2048,
          'time_elapsed_ms': 100,
          'stack_depth_used': 5,
        });
        expect(usage.memoryBytesUsed, 2048);
        expect(usage.timeElapsedMs, 100);
        expect(usage.stackDepthUsed, 5);
      });
    });

    group('toJson', () {
      test('serializes all fields', () {
        const usage = MontyResourceUsage(
          memoryBytesUsed: 512,
          timeElapsedMs: 25,
          stackDepthUsed: 3,
        );
        expect(usage.toJson(), {
          'memory_bytes_used': 512,
          'time_elapsed_ms': 25,
          'stack_depth_used': 3,
        });
      });
    });

    test('JSON round-trip', () {
      const original = MontyResourceUsage(
        memoryBytesUsed: 4096,
        timeElapsedMs: 200,
        stackDepthUsed: 15,
      );
      final restored = MontyResourceUsage.fromJson(original.toJson());
      expect(restored, original);
    });

    group('equality', () {
      test('equal when all fields match', () {
        const a = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        const b = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('not equal when memoryBytesUsed differs', () {
        const a = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        const b = MontyResourceUsage(
          memoryBytesUsed: 200,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        expect(a, isNot(b));
      });

      test('not equal when timeElapsedMs differs', () {
        const a = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        const b = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 20,
          stackDepthUsed: 2,
        );
        expect(a, isNot(b));
      });

      test('not equal when stackDepthUsed differs', () {
        const a = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        const b = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 3,
        );
        expect(a, isNot(b));
      });

      test('not equal to other types', () {
        const usage = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        expect(usage, isNot(42));
      });

      test('identical instances are equal', () {
        const usage = MontyResourceUsage(
          memoryBytesUsed: 100,
          timeElapsedMs: 10,
          stackDepthUsed: 2,
        );
        expect(usage == usage, isTrue);
      });
    });

    test('toString', () {
      const usage = MontyResourceUsage(
        memoryBytesUsed: 1024,
        timeElapsedMs: 50,
        stackDepthUsed: 10,
      );
      expect(
        usage.toString(),
        'MontyResourceUsage('
        'memoryBytesUsed: 1024, '
        'timeElapsedMs: 50, '
        'stackDepthUsed: 10)',
      );
    });

    group('malformed JSON', () {
      test('throws on missing fields', () {
        expect(
          () => MontyResourceUsage.fromJson(const <String, dynamic>{}),
          throwsA(isA<TypeError>()),
        );
      });

      test('throws on wrong field type', () {
        expect(
          () => MontyResourceUsage.fromJson(const {
            'memory_bytes_used': 'not_a_number',
            'time_elapsed_ms': 0,
            'stack_depth_used': 0,
          }),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
