import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 256,
    timeElapsedMs: 5,
    stackDepthUsed: 2,
  );

  group('MontyProgress', () {
    group('MontyComplete', () {
      test('constructs with result', () {
        const result = MontyResult(value: 42, usage: usage);
        const complete = MontyComplete(result: result);
        expect(complete.result, result);
      });

      test('is a MontyProgress', () {
        const complete = MontyComplete(
          result: MontyResult(value: 1, usage: usage),
        );
        expect(complete, isA<MontyProgress>());
      });

      group('fromJson', () {
        test('parses complete JSON', () {
          final complete = MontyComplete.fromJson(const {
            'type': 'complete',
            'result': {
              'value': 'done',
              'usage': {
                'memory_bytes_used': 256,
                'time_elapsed_ms': 5,
                'stack_depth_used': 2,
              },
            },
          });
          expect(complete.result.value, 'done');
          expect(complete.result.usage, usage);
        });
      });

      test('toJson', () {
        const complete = MontyComplete(
          result: MontyResult(value: 42, usage: usage),
        );
        final json = complete.toJson();
        expect(json['type'], 'complete');
        expect(json['result'], isA<Map<String, dynamic>>());
      });

      test('JSON round-trip', () {
        const original = MontyComplete(
          result: MontyResult(value: 'hello', usage: usage),
        );
        final restored = MontyComplete.fromJson(original.toJson());
        expect(restored, original);
      });

      group('equality', () {
        test('equal when result matches', () {
          const a = MontyComplete(
            result: MontyResult(value: 42, usage: usage),
          );
          const b = MontyComplete(
            result: MontyResult(value: 42, usage: usage),
          );
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('not equal when result differs', () {
          const a = MontyComplete(
            result: MontyResult(value: 1, usage: usage),
          );
          const b = MontyComplete(
            result: MontyResult(value: 2, usage: usage),
          );
          expect(a, isNot(b));
        });

        test('not equal to other types', () {
          const complete = MontyComplete(
            result: MontyResult(value: 42, usage: usage),
          );
          expect(complete, isNot(42));
        });

        test('identical instances are equal', () {
          const complete = MontyComplete(
            result: MontyResult(value: 42, usage: usage),
          );
          expect(complete == complete, isTrue);
        });
      });

      test('toString', () {
        const complete = MontyComplete(
          result: MontyResult(value: 42, usage: usage),
        );
        expect(
          complete.toString(),
          'MontyComplete(MontyResult.value(42))',
        );
      });
    });

    group('MontyPending', () {
      test('constructs with function name and arguments', () {
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: ['url', 42],
        );
        expect(pending.functionName, 'fetch');
        expect(pending.arguments, ['url', 42]);
      });

      test('is a MontyProgress', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
        );
        expect(pending, isA<MontyProgress>());
      });

      test('constructs with empty arguments', () {
        const pending = MontyPending(
          functionName: 'noop',
          arguments: [],
        );
        expect(pending.arguments, isEmpty);
      });

      group('fromJson', () {
        test('parses pending JSON', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'getData',
            'arguments': [1, 'two', true],
          });
          expect(pending.functionName, 'getData');
          expect(pending.arguments, [1, 'two', true]);
        });

        test('parses empty arguments', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'ping',
            'arguments': <dynamic>[],
          });
          expect(pending.arguments, isEmpty);
        });

        test('parses null arguments', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
            'arguments': [null, 1, null],
          });
          expect(pending.arguments, [null, 1, null]);
        });
      });

      test('toJson', () {
        const pending = MontyPending(
          functionName: 'send',
          arguments: ['data', 42],
        );
        expect(pending.toJson(), {
          'type': 'pending',
          'function_name': 'send',
          'arguments': ['data', 42],
        });
      });

      test('JSON round-trip', () {
        const original = MontyPending(
          functionName: 'compute',
          arguments: [1, 2, 3],
        );
        final restored = MontyPending.fromJson(original.toJson());
        expect(restored, original);
      });

      test('JSON round-trip with empty arguments', () {
        const original = MontyPending(
          functionName: 'noop',
          arguments: [],
        );
        final restored = MontyPending.fromJson(original.toJson());
        expect(restored, original);
      });

      group('equality', () {
        test('equal when all fields match', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [1, 'a'],
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [1, 'a'],
          );
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('equal with empty arguments', () {
          const a = MontyPending(functionName: 'fn', arguments: []);
          const b = MontyPending(functionName: 'fn', arguments: []);
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('not equal when functionName differs', () {
          const a = MontyPending(functionName: 'fn1', arguments: []);
          const b = MontyPending(functionName: 'fn2', arguments: []);
          expect(a, isNot(b));
        });

        test('not equal when arguments differ', () {
          const a = MontyPending(functionName: 'fn', arguments: [1]);
          const b = MontyPending(functionName: 'fn', arguments: [2]);
          expect(a, isNot(b));
        });

        test('not equal when argument count differs', () {
          const a = MontyPending(functionName: 'fn', arguments: [1]);
          const b = MontyPending(functionName: 'fn', arguments: [1, 2]);
          expect(a, isNot(b));
        });

        test('not equal to other types', () {
          const pending = MontyPending(functionName: 'fn', arguments: []);
          expect(pending, isNot('fn'));
        });

        test('identical instances are equal', () {
          const pending = MontyPending(functionName: 'fn', arguments: [1]);
          expect(pending == pending, isTrue);
        });
      });

      test('toString', () {
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: [42],
        );
        expect(pending.toString(), 'MontyPending(fetch, [42])');
      });
    });

    group('fromJson discriminator', () {
      test('dispatches to MontyComplete', () {
        final progress = MontyProgress.fromJson(const {
          'type': 'complete',
          'result': {
            'value': null,
            'usage': {
              'memory_bytes_used': 0,
              'time_elapsed_ms': 0,
              'stack_depth_used': 0,
            },
          },
        });
        expect(progress, isA<MontyComplete>());
      });

      test('dispatches to MontyPending', () {
        final progress = MontyProgress.fromJson(const {
          'type': 'pending',
          'function_name': 'fn',
          'arguments': <dynamic>[],
        });
        expect(progress, isA<MontyPending>());
      });

      test('throws on unknown type', () {
        expect(
          () => MontyProgress.fromJson(const {
            'type': 'unknown',
          }),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    test('pattern matching works on sealed class', () {
      const MontyProgress progress = MontyComplete(
        result: MontyResult(value: 'matched', usage: usage),
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName) => 'pending: $functionName',
      };

      expect(description, 'complete: matched');
    });

    test('pattern matching on pending', () {
      const MontyProgress progress = MontyPending(
        functionName: 'doWork',
        arguments: [1, 2],
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName, :final arguments) =>
          'pending: $functionName(${arguments.length} args)',
      };

      expect(description, 'pending: doWork(2 args)');
    });

    group('deep equality', () {
      test('nested maps are equal', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            {'key': 'val', 'nested': true},
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            {'key': 'val', 'nested': true},
          ],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('nested lists are equal', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            [1, 2, 3],
            [4, 5],
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            [1, 2, 3],
            [4, 5],
          ],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('nested maps differ', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            {'key': 'val1'},
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            {'key': 'val2'},
          ],
        );
        expect(a, isNot(b));
      });

      test('JSON round-trip with nested collections', () {
        const original = MontyPending(
          functionName: 'compute',
          arguments: [
            {'x': 1},
            [2, 3],
            'plain',
          ],
        );
        final restored = MontyPending.fromJson(original.toJson());
        expect(restored, original);
      });
    });

    group('fromJson null safety', () {
      test('missing arguments defaults to empty list', () {
        final pending = MontyPending.fromJson(const {
          'type': 'pending',
          'function_name': 'fn',
        });
        expect(pending.arguments, isEmpty);
      });

      test('null arguments defaults to empty list', () {
        final pending = MontyPending.fromJson(const {
          'type': 'pending',
          'function_name': 'fn',
          'arguments': null,
        });
        expect(pending.arguments, isEmpty);
      });
    });

    group('malformed JSON', () {
      test('MontyProgress.fromJson throws on missing type', () {
        expect(
          () => MontyProgress.fromJson(const <String, dynamic>{}),
          throwsA(isA<TypeError>()),
        );
      });

      test('MontyComplete.fromJson throws on missing result', () {
        expect(
          () => MontyComplete.fromJson(const {'type': 'complete'}),
          throwsA(isA<TypeError>()),
        );
      });

      test('MontyPending.fromJson throws on missing function_name', () {
        expect(
          () => MontyPending.fromJson(const {
            'type': 'pending',
            'arguments': <dynamic>[],
          }),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
