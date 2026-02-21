import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 512,
    timeElapsedMs: 10,
    stackDepthUsed: 3,
  );

  group('MontyResult', () {
    test('constructs value result', () {
      const result = MontyResult(value: 42, usage: usage);
      expect(result.value, 42);
      expect(result.error, isNull);
      expect(result.usage, usage);
      expect(result.isError, isFalse);
    });

    test('constructs error result', () {
      const error = MontyException(message: 'boom');
      const result = MontyResult(error: error, usage: usage);
      expect(result.value, isNull);
      expect(result.error, error);
      expect(result.usage, usage);
      expect(result.isError, isTrue);
    });

    test('constructs with null value', () {
      const result = MontyResult(usage: usage);
      expect(result.value, isNull);
      expect(result.error, isNull);
      expect(result.isError, isFalse);
    });

    test('value can be a string', () {
      const result = MontyResult(value: 'hello', usage: usage);
      expect(result.value, 'hello');
    });

    test('value can be a list', () {
      const result = MontyResult(
        value: [1, 2, 3],
        usage: usage,
      );
      expect(result.value, [1, 2, 3]);
    });

    test('value can be a map', () {
      const result = MontyResult(
        value: {'key': 'val'},
        usage: usage,
      );
      expect(result.value, {'key': 'val'});
    });

    group('fromJson', () {
      test('parses value result', () {
        final result = MontyResult.fromJson(const {
          'value': 99,
          'usage': {
            'memory_bytes_used': 512,
            'time_elapsed_ms': 10,
            'stack_depth_used': 3,
          },
        });
        expect(result.value, 99);
        expect(result.error, isNull);
        expect(result.usage, usage);
      });

      test('parses error result', () {
        final result = MontyResult.fromJson(const {
          'value': null,
          'error': {'message': 'fail'},
          'usage': {
            'memory_bytes_used': 512,
            'time_elapsed_ms': 10,
            'stack_depth_used': 3,
          },
        });
        expect(result.value, isNull);
        expect(result.error, const MontyException(message: 'fail'));
        expect(result.isError, isTrue);
      });

      test('parses null value without error key', () {
        final result = MontyResult.fromJson(const {
          'value': null,
          'usage': {
            'memory_bytes_used': 0,
            'time_elapsed_ms': 0,
            'stack_depth_used': 0,
          },
        });
        expect(result.value, isNull);
        expect(result.error, isNull);
      });
    });

    group('toJson', () {
      test('serializes value result', () {
        const result = MontyResult(value: 'hi', usage: usage);
        expect(result.toJson(), {
          'value': 'hi',
          'usage': {
            'memory_bytes_used': 512,
            'time_elapsed_ms': 10,
            'stack_depth_used': 3,
          },
        });
      });

      test('serializes error result', () {
        const result = MontyResult(
          error: MontyException(message: 'oops'),
          usage: usage,
        );
        final json = result.toJson();
        expect(json['error'], {'message': 'oops'});
        expect(json['value'], isNull);
      });
    });

    test('JSON round-trip for value result', () {
      const original = MontyResult(value: 42, usage: usage);
      final restored = MontyResult.fromJson(original.toJson());
      expect(restored, original);
    });

    test('JSON round-trip for error result', () {
      const original = MontyResult(
        error: MontyException(
          message: 'SyntaxError',
          filename: 'test.py',
          lineNumber: 1,
        ),
        usage: usage,
      );
      final restored = MontyResult.fromJson(original.toJson());
      expect(restored, original);
    });

    group('equality', () {
      test('equal when all fields match', () {
        const a = MontyResult(value: 42, usage: usage);
        const b = MontyResult(value: 42, usage: usage);
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('not equal when value differs', () {
        const a = MontyResult(value: 1, usage: usage);
        const b = MontyResult(value: 2, usage: usage);
        expect(a, isNot(b));
      });

      test('not equal when error differs', () {
        const a = MontyResult(
          error: MontyException(message: 'a'),
          usage: usage,
        );
        const b = MontyResult(
          error: MontyException(message: 'b'),
          usage: usage,
        );
        expect(a, isNot(b));
      });

      test('not equal when usage differs', () {
        const otherUsage = MontyResourceUsage(
          memoryBytesUsed: 999,
          timeElapsedMs: 10,
          stackDepthUsed: 3,
        );
        const a = MontyResult(value: 42, usage: usage);
        const b = MontyResult(value: 42, usage: otherUsage);
        expect(a, isNot(b));
      });

      test('not equal to other types', () {
        const result = MontyResult(value: 42, usage: usage);
        expect(result, isNot(42));
      });

      test('identical instances are equal', () {
        const result = MontyResult(value: 42, usage: usage);
        expect(result == result, isTrue);
      });
    });

    group('toString', () {
      test('value result', () {
        const result = MontyResult(value: 42, usage: usage);
        expect(result.toString(), 'MontyResult.value(42)');
      });

      test('error result', () {
        const result = MontyResult(
          error: MontyException(message: 'fail'),
          usage: usage,
        );
        expect(result.toString(), 'MontyResult.error(fail)');
      });

      test('null value result', () {
        const result = MontyResult(usage: usage);
        expect(result.toString(), 'MontyResult.value(null)');
      });
    });

    group('malformed JSON', () {
      test('throws on missing usage', () {
        expect(
          () => MontyResult.fromJson(const {'value': 42}),
          throwsA(isA<TypeError>()),
        );
      });

      test('throws on wrong error type', () {
        expect(
          () => MontyResult.fromJson(const {
            'value': null,
            'error': 'not_a_map',
            'usage': {
              'memory_bytes_used': 0,
              'time_elapsed_ms': 0,
              'stack_depth_used': 0,
            },
          }),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
