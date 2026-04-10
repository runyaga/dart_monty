import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

void main() {
  const usage = MontyResourceUsage(
    memoryBytesUsed: 256,
    timeElapsedMs: 5,
    stackDepthUsed: 2,
  );

  group('MontyProgress', () {
    group('MontyComplete', () {
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
          expect(complete.result.value, const MontyString('done'));
          expect(complete.result.usage, usage);
        });
      });

      test('toJson', () {
        const complete = MontyComplete(
          result: MontyResult(value: MontyInt(42), usage: usage),
        );
        final json = complete.toJson();
        expect(json['type'], 'complete');
        expect(json['result'], isA<Map<String, dynamic>>());
      });

      test('JSON round-trip', () {
        const original = MontyComplete(
          result: MontyResult(value: MontyString('hello'), usage: usage),
        );
        final restored = MontyComplete.fromJson(original.toJson());
        expect(restored, original);
      });

      group('equality', () {
        test('equal when result matches', () {
          const a = MontyComplete(
            result: MontyResult(value: MontyInt(42), usage: usage),
          );
          const b = MontyComplete(
            result: MontyResult(value: MontyInt(42), usage: usage),
          );
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('not equal when result differs', () {
          const a = MontyComplete(
            result: MontyResult(value: MontyInt(1), usage: usage),
          );
          const b = MontyComplete(
            result: MontyResult(value: MontyInt(2), usage: usage),
          );
          expect(a, isNot(b));
        });

        test('not equal to other types', () {
          const complete = MontyComplete(
            result: MontyResult(value: MontyInt(42), usage: usage),
          );
          expect(complete, isNot(42));
        });

        test('identical instances are equal', () {
          const complete = MontyComplete(
            result: MontyResult(value: MontyInt(42), usage: usage),
          );
          expect(complete == complete, isTrue);
        });
      });

      test('toString', () {
        const complete = MontyComplete(
          result: MontyResult(value: MontyInt(42), usage: usage),
        );
        expect(
          complete.toString(),
          'MontyComplete(MontyResult.value(MontyInt(42)))',
        );
      });
    });

    group('MontyPending', () {
      group('fromJson', () {
        test('parses pending JSON', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'getData',
            'arguments': [1, 'two', true],
          });
          expect(pending.functionName, 'getData');
          expect(pending.arguments, [
            const MontyInt(1),
            const MontyString('two'),
            const MontyBool(true),
          ]);
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
          expect(pending.arguments, [
            const MontyNull(),
            const MontyInt(1),
            const MontyNull(),
          ]);
        });

        test('parses kwargs', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fetch',
            'arguments': ['url'],
            'kwargs': {'timeout': 30},
          });
          expect(pending.kwargs, {'timeout': const MontyInt(30)});
        });

        test('parses null kwargs as null', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
          });
          expect(pending.kwargs, isNull);
        });

        test('parses empty kwargs as empty map', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
            'kwargs': <String, dynamic>{},
          });
          expect(pending.kwargs, isNotNull);
          expect(pending.kwargs, isEmpty);
        });

        test('parses call_id', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
            'call_id': 7,
          });
          expect(pending.callId, 7);
        });

        test('defaults call_id to 0', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
          });
          expect(pending.callId, 0);
        });

        test('parses method_call', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'obj.method',
            'method_call': true,
          });
          expect(pending.methodCall, isTrue);
        });

        test('defaults method_call to false', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'fn',
          });
          expect(pending.methodCall, isFalse);
        });

        test('parses all M7A fields together', () {
          final pending = MontyPending.fromJson(const {
            'type': 'pending',
            'function_name': 'db.query',
            'arguments': ['SELECT * FROM users'],
            'kwargs': {'limit': 10, 'offset': 0},
            'call_id': 42,
            'method_call': true,
          });
          expect(pending.functionName, 'db.query');
          expect(pending.arguments, [const MontyString('SELECT * FROM users')]);
          expect(pending.kwargs, {
            'limit': const MontyInt(10),
            'offset': const MontyInt(0),
          });
          expect(pending.callId, 42);
          expect(pending.methodCall, isTrue);
        });
      });

      test('toJson', () {
        const pending = MontyPending(
          functionName: 'send',
          arguments: [MontyString('data'), MontyInt(42)],
        );
        expect(pending.toJson(), {
          'type': 'pending',
          'function_name': 'send',
          'arguments': ['data', 42],
        });
      });

      test('toJson includes kwargs when non-null', () {
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: [],
          kwargs: {'timeout': MontyInt(5)},
        );
        final json = pending.toJson();
        expect(json['kwargs'], {'timeout': 5});
      });

      test('toJson omits kwargs when null', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
        );
        final json = pending.toJson();
        expect(json.containsKey('kwargs'), isFalse);
      });

      test('toJson includes callId when non-zero', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
          callId: 7,
        );
        final json = pending.toJson();
        expect(json['call_id'], 7);
      });

      test('toJson omits callId when zero', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
        );
        final json = pending.toJson();
        expect(json.containsKey('call_id'), isFalse);
      });

      test('toJson includes methodCall when true', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
          methodCall: true,
        );
        final json = pending.toJson();
        expect(json['method_call'], isTrue);
      });

      test('toJson omits methodCall when false', () {
        const pending = MontyPending(
          functionName: 'fn',
          arguments: [],
        );
        final json = pending.toJson();
        expect(json.containsKey('method_call'), isFalse);
      });

      test('JSON round-trip', () {
        const original = MontyPending(
          functionName: 'compute',
          arguments: [MontyInt(1), MontyInt(2), MontyInt(3)],
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

      test('JSON round-trip with all M7A fields', () {
        const original = MontyPending(
          functionName: 'db.query',
          arguments: [MontyString('SELECT 1')],
          kwargs: {'limit': MontyInt(10)},
          callId: 42,
          methodCall: true,
        );
        final restored = MontyPending.fromJson(original.toJson());
        expect(restored, original);
      });

      test('JSON round-trip with empty kwargs', () {
        const original = MontyPending(
          functionName: 'fn',
          arguments: [],
          kwargs: {},
        );
        final restored = MontyPending.fromJson(original.toJson());
        expect(restored, original);
      });

      group('equality', () {
        test('equal when all fields match', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [MontyInt(1), MontyString('a')],
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [MontyInt(1), MontyString('a')],
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
          const a = MontyPending(functionName: 'fn', arguments: [MontyInt(1)]);
          const b = MontyPending(functionName: 'fn', arguments: [MontyInt(2)]);
          expect(a, isNot(b));
        });

        test('not equal when argument count differs', () {
          const a = MontyPending(functionName: 'fn', arguments: [MontyInt(1)]);
          const b = MontyPending(
            functionName: 'fn',
            arguments: [MontyInt(1), MontyInt(2)],
          );
          expect(a, isNot(b));
        });

        test('not equal when kwargs differs', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'a': MontyInt(1)},
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'a': MontyInt(2)},
          );
          expect(a, isNot(b));
        });

        test('not equal when one has kwargs and other does not', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'a': MontyInt(1)},
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [],
          );
          expect(a, isNot(b));
        });

        test('equal with same kwargs', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'key': MontyString('val')},
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [],
            kwargs: {'key': MontyString('val')},
          );
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('not equal when callId differs', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [],
            callId: 1,
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [],
            callId: 2,
          );
          expect(a, isNot(b));
        });

        test('not equal when methodCall differs', () {
          const a = MontyPending(
            functionName: 'fn',
            arguments: [],
          );
          const b = MontyPending(
            functionName: 'fn',
            arguments: [],
            methodCall: true,
          );
          expect(a, isNot(b));
        });

        test('not equal to other types', () {
          const pending = MontyPending(functionName: 'fn', arguments: []);
          expect(pending, isNot('fn'));
        });

        test('identical instances are equal', () {
          const pending = MontyPending(
            functionName: 'fn',
            arguments: [MontyInt(1)],
          );
          expect(pending == pending, isTrue);
        });
      });

      test('toString', () {
        const pending = MontyPending(
          functionName: 'fetch',
          arguments: [MontyInt(42)],
        );
        expect(pending.toString(), 'MontyPending(fetch, [MontyInt(42)])');
      });
    });

    group('MontyResolveFutures', () {
      group('fromJson', () {
        test('parses resolve_futures JSON', () {
          final futures = MontyResolveFutures.fromJson(const {
            'type': 'resolve_futures',
            'pending_call_ids': <dynamic>[0, 1, 2],
          });
          expect(futures.pendingCallIds, [0, 1, 2]);
        });

        test('parses empty call IDs', () {
          final futures = MontyResolveFutures.fromJson(const {
            'type': 'resolve_futures',
            'pending_call_ids': <dynamic>[],
          });
          expect(futures.pendingCallIds, isEmpty);
        });
      });

      group('toJson', () {
        test('serializes to JSON', () {
          const futures = MontyResolveFutures(pendingCallIds: [0, 1]);
          expect(futures.toJson(), {
            'type': 'resolve_futures',
            'pending_call_ids': [0, 1],
          });
        });
      });

      test('JSON round-trip', () {
        const original = MontyResolveFutures(pendingCallIds: [3, 7, 12]);
        final restored = MontyResolveFutures.fromJson(original.toJson());
        expect(restored, original);
      });

      group('equality', () {
        test('equal instances', () {
          const a = MontyResolveFutures(pendingCallIds: [0, 1]);
          const b = MontyResolveFutures(pendingCallIds: [0, 1]);
          expect(a, b);
          expect(a.hashCode, b.hashCode);
        });

        test('different call IDs', () {
          const a = MontyResolveFutures(pendingCallIds: [0, 1]);
          const b = MontyResolveFutures(pendingCallIds: [0, 2]);
          expect(a, isNot(b));
        });

        test('different lengths', () {
          const a = MontyResolveFutures(pendingCallIds: [0]);
          const b = MontyResolveFutures(pendingCallIds: [0, 1]);
          expect(a, isNot(b));
        });

        test('not equal to other types', () {
          const futures = MontyResolveFutures(pendingCallIds: [0]);
          expect(futures, isNot('foo'));
        });

        test('identical instances are equal', () {
          const futures = MontyResolveFutures(pendingCallIds: [0, 1]);
          expect(futures == futures, isTrue);
        });
      });

      test('toString', () {
        const futures = MontyResolveFutures(pendingCallIds: [0, 1, 2]);
        expect(futures.toString(), 'MontyResolveFutures([0, 1, 2])');
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

      test('dispatches to MontyResolveFutures', () {
        final progress = MontyProgress.fromJson(const {
          'type': 'resolve_futures',
          'pending_call_ids': <dynamic>[0, 1],
        });
        expect(progress, isA<MontyResolveFutures>());
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
        result: MontyResult(value: MontyString('matched'), usage: usage),
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName) => 'pending: $functionName',
        MontyOsCall(:final operationName) => 'os_call: $operationName',
        MontyResolveFutures(:final pendingCallIds) =>
          'futures: $pendingCallIds',
      };

      expect(description, 'complete: MontyString(matched)');
    });

    test('pattern matching on pending', () {
      const MontyProgress progress = MontyPending(
        functionName: 'doWork',
        arguments: [MontyInt(1), MontyInt(2)],
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName, :final arguments) =>
          'pending: $functionName(${arguments.length} args)',
        MontyOsCall(:final operationName) => 'os_call: $operationName',
        MontyResolveFutures(:final pendingCallIds) =>
          'futures: $pendingCallIds',
      };

      expect(description, 'pending: doWork(2 args)');
    });

    test('pattern matching with kwargs', () {
      const MontyProgress progress = MontyPending(
        functionName: 'fetch',
        arguments: [MontyString('url')],
        kwargs: {'timeout': MontyInt(30)},
        callId: 5,
        methodCall: true,
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName, :final kwargs, :final callId) =>
          'pending: $functionName(kwargs=$kwargs, callId=$callId)',
        MontyOsCall(:final operationName) => 'os_call: $operationName',
        MontyResolveFutures(:final pendingCallIds) =>
          'futures: $pendingCallIds',
      };

      expect(
        description,
        'pending: fetch(kwargs={timeout: MontyInt(30)}, callId=5)',
      );
    });

    test('pattern matching on resolve_futures', () {
      const MontyProgress progress = MontyResolveFutures(
        pendingCallIds: [0, 1, 2],
      );

      final description = switch (progress) {
        MontyComplete(:final result) => 'complete: ${result.value}',
        MontyPending(:final functionName) => 'pending: $functionName',
        MontyOsCall(:final operationName) => 'os_call: $operationName',
        MontyResolveFutures(:final pendingCallIds) =>
          'futures: $pendingCallIds',
      };

      expect(description, 'futures: [0, 1, 2]');
    });

    group('deep equality', () {
      test('nested maps are equal', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyDict({
              'key': MontyString('val'),
              'nested': MontyBool(true),
            }),
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyDict({
              'key': MontyString('val'),
              'nested': MontyBool(true),
            }),
          ],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('nested lists are equal', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
            MontyList([MontyInt(4), MontyInt(5)]),
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
            MontyList([MontyInt(4), MontyInt(5)]),
          ],
        );
        expect(a, b);
        expect(a.hashCode, b.hashCode);
      });

      test('nested maps differ', () {
        const a = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyDict({'key': MontyString('val1')}),
          ],
        );
        const b = MontyPending(
          functionName: 'fn',
          arguments: [
            MontyDict({'key': MontyString('val2')}),
          ],
        );
        expect(a, isNot(b));
      });

      test('JSON round-trip with nested collections', () {
        const original = MontyPending(
          functionName: 'compute',
          arguments: [
            MontyDict({'x': MontyInt(1)}),
            MontyList([MontyInt(2), MontyInt(3)]),
            MontyString('plain'),
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

      test('MontyResolveFutures.fromJson throws on missing call_ids', () {
        expect(
          () => MontyResolveFutures.fromJson(
            const {'type': 'resolve_futures'},
          ),
          throwsA(isA<TypeError>()),
        );
      });
    });
  });
}
