import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  group('MontyLimits', () {
    test('constructs with all fields', () {
      const limits = MontyLimits(
        memoryBytes: 1048576,
        timeoutMs: 5000,
        stackDepth: 100,
      );
      expect(limits.memoryBytes, 1048576);
      expect(limits.timeoutMs, 5000);
      expect(limits.stackDepth, 100);
    });

    test('constructs with all null', () {
      const limits = MontyLimits();
      expect(limits.memoryBytes, isNull);
      expect(limits.timeoutMs, isNull);
      expect(limits.stackDepth, isNull);
    });

    test('constructs with partial fields', () {
      const limits = MontyLimits(timeoutMs: 3000);
      expect(limits.memoryBytes, isNull);
      expect(limits.timeoutMs, 3000);
      expect(limits.stackDepth, isNull);
    });

    group('fromJson', () {
      test('parses full JSON', () {
        final limits = MontyLimits.fromJson(const {
          'memory_bytes': 2097152,
          'timeout_ms': 10000,
          'stack_depth': 50,
        });
        expect(limits.memoryBytes, 2097152);
        expect(limits.timeoutMs, 10000);
        expect(limits.stackDepth, 50);
      });

      test('parses empty JSON', () {
        final limits = MontyLimits.fromJson(const <String, dynamic>{});
        expect(limits.memoryBytes, isNull);
        expect(limits.timeoutMs, isNull);
        expect(limits.stackDepth, isNull);
      });

      test('parses partial JSON', () {
        final limits = MontyLimits.fromJson(const {
          'timeout_ms': 1000,
        });
        expect(limits.memoryBytes, isNull);
        expect(limits.timeoutMs, 1000);
        expect(limits.stackDepth, isNull);
      });
    });

    group('toJson', () {
      test('serializes all fields', () {
        const limits = MontyLimits(
          memoryBytes: 4096,
          timeoutMs: 500,
          stackDepth: 25,
        );
        expect(limits.toJson(), {
          'memory_bytes': 4096,
          'timeout_ms': 500,
          'stack_depth': 25,
        });
      });

      test('omits null fields', () {
        const limits = MontyLimits();
        expect(limits.toJson(), <String, dynamic>{});
      });

      test('omits only null fields', () {
        const limits = MontyLimits(memoryBytes: 1024);
        expect(limits.toJson(), {'memory_bytes': 1024});
      });
    });

    test('JSON round-trip with all fields', () {
      const original = MontyLimits(
        memoryBytes: 8192,
        timeoutMs: 2000,
        stackDepth: 75,
      );
      final restored = MontyLimits.fromJson(original.toJson());
      expect(restored, original);
    });

    test('JSON round-trip with all null', () {
      const original = MontyLimits();
      final restored = MontyLimits.fromJson(original.toJson());
      expect(restored, original);
    });

    group('equality', () {
      test('equal when all fields match', () {
        const a = MontyLimits(memoryBytes: 100, timeoutMs: 10, stackDepth: 5);
        const b = MontyLimits(memoryBytes: 100, timeoutMs: 10, stackDepth: 5);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('equal when both all null', () {
        const a = MontyLimits();
        const b = MontyLimits();
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('not equal when memoryBytes differs', () {
        const a = MontyLimits(memoryBytes: 100);
        const b = MontyLimits(memoryBytes: 200);
        expect(a, isNot(b));
      });

      test('not equal when timeoutMs differs', () {
        const a = MontyLimits(timeoutMs: 100);
        const b = MontyLimits(timeoutMs: 200);
        expect(a, isNot(b));
      });

      test('not equal when stackDepth differs', () {
        const a = MontyLimits(stackDepth: 10);
        const b = MontyLimits(stackDepth: 20);
        expect(a, isNot(b));
      });

      test('not equal to other types', () {
        const limits = MontyLimits();
        expect(limits, isNot(42));
      });

      test('identical instances are equal', () {
        const limits = MontyLimits(memoryBytes: 100);
        expect(limits == limits, isTrue);
      });
    });

    test('toString', () {
      const limits = MontyLimits(
        memoryBytes: 1024,
        timeoutMs: 500,
        stackDepth: 10,
      );
      expect(
        limits.toString(),
        'MontyLimits('
        'memoryBytes: 1024, '
        'timeoutMs: 500, '
        'stackDepth: 10)',
      );
    });

    test('toString with nulls', () {
      const limits = MontyLimits();
      expect(
        limits.toString(),
        'MontyLimits('
        'memoryBytes: null, '
        'timeoutMs: null, '
        'stackDepth: null)',
      );
    });

    group('malformed JSON', () {
      test('throws on wrong field type', () {
        expect(
          () => MontyLimits.fromJson(const {
            'memory_bytes': 'not_a_number',
          }),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
