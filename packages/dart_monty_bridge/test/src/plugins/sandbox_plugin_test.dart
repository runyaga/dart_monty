import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 1024,
  timeElapsedMs: 10,
  stackDepthUsed: 5,
);

/// Creates a [MockMontyPlatform] that runs code to completion immediately.
MockMontyPlatform _completingMock() {
  return MockMontyPlatform()
    ..enqueueProgress(const MontyComplete(result: MontyResult(usage: _usage)));
}

/// Creates a [MockMontyPlatform] that completes with [value] and [printOutput].
MockMontyPlatform _completingMockWithResult({
  Object? value,
  String? printOutput,
}) {
  return MockMontyPlatform()..enqueueProgress(
    MontyComplete(
      result: MontyResult(
        value: value,
        usage: _usage,
        printOutput: printOutput,
      ),
    ),
  );
}

/// Creates a [MockMontyPlatform] that fails with [message].
MockMontyPlatform _failingMock(String message) {
  return MockMontyPlatform()..enqueueProgress(
    MontyComplete(
      result: MontyResult(
        error: MontyException(message: message),
        usage: _usage,
      ),
    ),
  );
}

/// Creates a [MockMontyPlatform] that fails with a structured [MontyException].
MockMontyPlatform _failingMockStructured({
  required String message,
  String? filename,
  int? lineNumber,
  int? columnNumber,
  String? excType,
}) {
  return MockMontyPlatform()..enqueueProgress(
    MontyComplete(
      result: MontyResult(
        error: MontyException(
          message: message,
          filename: filename,
          lineNumber: lineNumber,
          columnNumber: columnNumber,
          excType: excType,
        ),
        usage: _usage,
      ),
    ),
  );
}

void main() {
  group('SandboxPlugin', () {
    group('metadata', () {
      test('namespace is "sandbox"', () {
        final plugin = SandboxPlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.namespace, 'sandbox');
      });

      test('has system prompt context', () {
        final plugin = SandboxPlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.systemPromptContext, isNotNull);
        expect(plugin.systemPromptContext, contains('sandboxed'));
      });

      test('provides 8 host functions', () {
        final plugin = SandboxPlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.functions, hasLength(8));
      });

      test('all function names start with sandbox_', () {
        final plugin = SandboxPlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        for (final fn in plugin.functions) {
          expect(fn.schema.name, startsWith('sandbox_'));
        }
      });

      test('registers on PluginRegistry without collision', () {
        final registry = PluginRegistry()
          ..register(
            SandboxPlugin(platformFactory: () async => MockMontyPlatform()),
          );
        expect(registry.plugins, hasLength(1));
      });
    });

    group('sandbox_spawn', () {
      test('returns an integer handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final handle = await spawn({'code': 'x = 1'});

        expect(handle, isA<int>());
        expect(handle, 0);
      });

      test('sequential spawns return incrementing handles', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final h0 = await spawn({'code': 'a'});
        final h1 = await spawn({'code': 'b'});
        final h2 = await spawn({'code': 'c'});

        expect(h0, 0);
        expect(h1, 1);
        expect(h2, 2);
      });

      test('passes code to child platform start()', () async {
        final mock = _completingMock();
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'print("hello")'});

        // The bridge wraps code with print preamble, so check the mock
        // received something containing our code.
        expect(mock.lastStartCode, contains('print("hello")'));
      });

      test('child platform is disposed after completion', () async {
        final mock = _completingMock();
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': '42'});

        await await_({'handle': handle! as int});

        expect(mock.isDisposed, isTrue);
      });

      test('applies timeout_ms and memory_bytes to child limits', () async {
        final mock = _completingMock();
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': '1', 'timeout_ms': 5000, 'memory_bytes': 1048576});

        // Give the bridge time to call start().
        await Future<void>.delayed(Duration.zero);

        expect(mock.lastStartLimits, isNotNull);
        expect(mock.lastStartLimits!.timeoutMs, 5000);
        expect(mock.lastStartLimits!.memoryBytes, 1048576);
      });

      test('throws StateError when disposed', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        await plugin.onDispose();
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        expect(
          () => spawn({'code': '1'}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('disposed'),
            ),
          ),
        );
      });
    });

    group('sandbox_await', () {
      test('returns null for child with no return value', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': 'x = 1'});
        final result = await await_({'handle': handle! as int});

        expect(result, isNull);
      });

      test('returns child return value', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMockWithResult(value: 42),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': '42'});
        final result = await await_({'handle': handle! as int});

        expect(result, 42);
      });

      test('throws ChildSandboxException for failed child', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _failingMock('NameError: x'),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': 'x'});

        expect(
          () => await_({'handle': handle! as int}),
          throwsA(
            isA<ChildSandboxException>()
                .having((e) => e.childId, 'childId', handle)
                .having((e) => e.message, 'message', contains('NameError')),
          ),
        );
      });

      test(
        'preserves MontyException fields through ChildSandboxException',
        () async {
          final plugin = SandboxPlugin(
            platformFactory: () async => _failingMockStructured(
              message: 'NameError: undefined_var',
              filename: '<code>',
              lineNumber: 7,
              columnNumber: 4,
              excType: 'NameError',
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': 'undefined_var'});

          try {
            await await_({'handle': handle! as int});
            fail('Expected ChildSandboxException');
          } on ChildSandboxException catch (e) {
            expect(e.childId, handle);
            expect(e.message, contains('NameError'));
            expect(e.exception, isNotNull);
            expect(e.exception!.excType, 'NameError');
            expect(e.exception!.filename, '<code>');
            // Line number is adjusted by bridge preamble offset (5 lines).
            expect(e.exception!.lineNumber, 7 - 5);
            expect(e.exception!.columnNumber, 4);
          }
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final await_ = _findHandler(plugin, 'sandbox_await');

        expect(() => await_({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_await_all', () {
      test('returns results for all children', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');
        final h0 = await spawn({'code': 'a'});
        final h1 = await spawn({'code': 'b'});

        final results = await awaitAll({
          'handles': <Object?>[h0, h1],
        });

        expect(results, isA<List<Object?>>());
        expect(results! as List<Object?>, hasLength(2));
      });

      test('throws if any child fails', () async {
        var callCount = 0;
        final plugin = SandboxPlugin(
          platformFactory: () async {
            callCount++;
            if (callCount == 2) return _failingMock('boom');
            return _completingMock();
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');
        final h0 = await spawn({'code': 'ok'});
        final h1 = await spawn({'code': 'fail'});

        expect(
          () => awaitAll({
            'handles': <Object?>[h0, h1],
          }),
          throwsA(isA<ChildSandboxException>()),
        );
      });

      test('throws ArgumentError for unknown handle in list', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');

        expect(
          () => awaitAll({
            'handles': <Object?>[42],
          }),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('sandbox_is_alive', () {
      test('returns true while child is running', () async {
        // Use a slow platform that doesn't resolve start() immediately.
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);

        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn({'code': '1'});

        // Bridge is waiting for start() to complete — child is alive.
        final alive = await isAlive({'handle': handle! as int});
        expect(alive, isTrue);

        // Unblock and clean up.
        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
        await plugin.onDispose();
      });

      test('returns false after child completes', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        final alive = await isAlive({'handle': handle as int});
        expect(alive, isFalse);
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');

        expect(() => isAlive({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_cancel', () {
      test('cancels a running child', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final cancel = _findHandler(plugin, 'sandbox_cancel');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn({'code': 'wait_forever()'});

        await cancel({'handle': handle! as int});

        final alive = await isAlive({'handle': handle as int});
        expect(alive, isFalse);
        expect(mock.isDisposed, isTrue);

        // Unblock the suspended bridge.
        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
      });

      test('no-op for already finished child', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final cancel = _findHandler(plugin, 'sandbox_cancel');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        final result = await cancel({'handle': handle as int});
        expect(result, isNull);
      });

      test('await on cancelled child throws', () async {
        final startCompleter = Completer<MontyProgress>();
        final plugin = SandboxPlugin(
          platformFactory: () async => _SlowMockPlatform(startCompleter.future),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final cancel = _findHandler(plugin, 'sandbox_cancel');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': 'wait_forever()'});

        await cancel({'handle': handle! as int});

        expect(
          () => await_({'handle': handle as int}),
          throwsA(
            isA<ChildSandboxException>()
                .having((e) => e.childId, 'childId', handle)
                .having((e) => e.message, 'message', 'cancelled')
                .having((e) => e.exception, 'exception', isNull),
          ),
        );

        // Unblock the suspended bridge so _run() can finish cleanly.
        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
      });
    });

    group('sandbox_get_output', () {
      test('returns print output from completed child', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async =>
              _completingMockWithResult(printOutput: 'hello world\n'),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn({'code': 'print("hello world")'});

        await await_({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, 'hello world\n');
      });

      test('returns null when child had no print output', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn({'code': '42'});

        await await_({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, isNull);
      });

      test('throws StateError when child is still running', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn({'code': 'print("hi")'});

        expect(
          () => getOutput({'handle': handle! as int}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('still running'),
            ),
          ),
        );

        // Unblock and clean up.
        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
        await plugin.onDispose();
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final getOutput = _findHandler(plugin, 'sandbox_get_output');

        expect(() => getOutput({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_gather', () {
      test(
        'returns attributed results with handle, value, and output',
        () async {
          var callCount = 0;
          final plugin = SandboxPlugin(
            platformFactory: () async {
              callCount++;
              return _completingMockWithResult(
                value: callCount,
                printOutput: 'output_$callCount\n',
              );
            },
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final gather = _findHandler(plugin, 'sandbox_gather');

          final h0 = (await spawn({'code': 'a'}))! as int;
          final h1 = (await spawn({'code': 'b'}))! as int;

          final result =
              (await gather({
                    'handles': [h0, h1],
                  }))!
                  as List<Object?>;

          expect(result, hasLength(2));
          final r0 = result[0]! as Map<String, Object?>;
          final r1 = result[1]! as Map<String, Object?>;

          expect(r0['handle'], h0);
          expect(r0['value'], isNotNull);
          expect(r0['output'], isNotNull);
          expect(r1['handle'], h1);
          expect(r1['value'], isNotNull);
          expect(r1['output'], isNotNull);
        },
      );

      test('preserves handle order', () async {
        var callCount = 0;
        final plugin = SandboxPlugin(
          platformFactory: () async {
            callCount++;
            return _completingMockWithResult(value: callCount * 10);
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn({'code': 'a'}))! as int;
        final h1 = (await spawn({'code': 'b'}))! as int;
        final h2 = (await spawn({'code': 'c'}))! as int;

        // Request in reverse order.
        final result =
            (await gather({
                  'handles': [h2, h0, h1],
                }))!
                as List<Object?>;

        expect(result, hasLength(3));
        expect((result[0]! as Map)['handle'], h2);
        expect((result[1]! as Map)['handle'], h0);
        expect((result[2]! as Map)['handle'], h1);
      });

      test('handles null printOutput (child with no print)', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMockWithResult(value: 42),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn({'code': 'a'}))! as int;

        final result =
            (await gather({
                  'handles': [h0],
                }))!
                as List<Object?>;

        expect(result, hasLength(1));
        final r0 = result[0]! as Map<String, Object?>;
        expect(r0['handle'], h0);
        expect(r0['value'], 42);
        expect(r0['output'], isNull);
      });

      test('throws ChildSandboxException if any child fails', () async {
        var callCount = 0;
        final plugin = SandboxPlugin(
          platformFactory: () async {
            callCount++;
            if (callCount == 2) return _failingMock('child failed');
            return _completingMockWithResult(value: callCount);
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn({'code': 'a'}))! as int;
        final h1 = (await spawn({'code': 'b'}))! as int;

        expect(
          () => gather({
            'handles': [h0, h1],
          }),
          throwsA(isA<ChildSandboxException>()),
        );
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final gather = _findHandler(plugin, 'sandbox_gather');

        expect(
          () => gather({
            'handles': [999],
          }),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('works with single handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async =>
              _completingMockWithResult(value: 'solo', printOutput: 'hi\n'),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn({'code': 'a'}))! as int;

        final result =
            (await gather({
                  'handles': [h0],
                }))!
                as List<Object?>;

        expect(result, hasLength(1));
        final r0 = result[0]! as Map<String, Object?>;
        expect(r0['handle'], h0);
        expect(r0['value'], 'solo');
        expect(r0['output'], 'hi\n');
      });
    });

    group('sandbox_free', () {
      test('removes completed child from map', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        // Handle is now unknown.
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        expect(
          () => getOutput({'handle': handle}),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('throws StateError when child is still running', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn({'code': '1'});

        expect(
          () => free({'handle': handle! as int}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('still running'),
            ),
          ),
        );

        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
        await plugin.onDispose();
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final free = _findHandler(plugin, 'sandbox_free');

        expect(() => free({'handle': 999}), throwsA(isA<ArgumentError>()));
      });

      test('double free throws ArgumentError', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        expect(() => free({'handle': handle}), throwsA(isA<ArgumentError>()));
      });
    });

    group('failed child print output', () {
      test('get_output returns print output from failed child', () async {
        // A child that prints then fails — the mock simulates this by
        // returning an error result with printOutput set.
        final mock = MockMontyPlatform()
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                error: MontyException(message: 'NameError: x'),
                usage: _usage,
                printOutput: 'debug line\n',
              ),
            ),
          );
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn({'code': 'print("debug line"); x'});

        // Await will throw because the child failed.
        await expectLater(
          () => await_({'handle': handle! as int}),
          throwsA(isA<ChildSandboxException>()),
        );

        final output = await getOutput({'handle': handle! as int});
        expect(output, contains('debug'));
      });
    });

    group('depth limiting', () {
      test('rejects spawn when currentDepth >= maxDepth', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          maxDepth: 2,
          currentDepth: 2,
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        expect(
          () => spawn({'code': '1'}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('recursion depth'),
            ),
          ),
        );
      });

      test('allows spawn when currentDepth < maxDepth', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          currentDepth: 1,
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final handle = await spawn({'code': '1'});
        expect(handle, isA<int>());
      });
    });

    group('concurrency limiting', () {
      test('rejects spawn when maxChildren reached', () async {
        final completers = <Completer<MontyProgress>>[];
        final plugin = SandboxPlugin(
          platformFactory: () async {
            final c = Completer<MontyProgress>();
            completers.add(c);
            return _SlowMockPlatform(c.future);
          },
          maxChildren: 2,
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'a'});
        await spawn({'code': 'b'});

        expect(
          () => spawn({'code': 'c'}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Maximum concurrent'),
            ),
          ),
        );

        // Unblock all children and dispose.
        for (final c in completers) {
          c.complete(const MontyComplete(result: MontyResult(usage: _usage)));
        }
        await plugin.onDispose();
      });
    });

    group('ChildSandboxException', () {
      test('toString includes childId and message', () {
        const e = ChildSandboxException(childId: 3, message: 'boom');
        expect(e.toString(), 'ChildSandboxException(child 3): boom');
      });

      test('exception field is null for non-Python errors', () {
        const e = ChildSandboxException(childId: 0, message: 'cancelled');
        expect(e.exception, isNull);
      });

      test('infrastructure error produces null exception field', () async {
        // A platform whose start() throws a non-MontyException error.
        // The bridge catches it via `on Object` and emits BridgeRunError
        // without a MontyException.
        final plugin = SandboxPlugin(
          platformFactory: () async => _InfraErrorMock(),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': '1'});

        expect(
          () => await_({'handle': handle! as int}),
          throwsA(
            isA<ChildSandboxException>()
                .having((e) => e.exception, 'exception', isNull)
                .having((e) => e.message, 'message', contains('infra boom')),
          ),
        );
      });
    });

    group('onDispose', () {
      test('cancels all living children', () async {
        final completers = <Completer<MontyProgress>>[];
        final mocks = <_SlowMockPlatform>[];
        final plugin = SandboxPlugin(
          platformFactory: () async {
            final c = Completer<MontyProgress>();
            completers.add(c);
            final m = _SlowMockPlatform(c.future);
            mocks.add(m);
            return m;
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'a'});
        await spawn({'code': 'b'});

        await plugin.onDispose();

        for (final mock in mocks) {
          expect(mock.isDisposed, isTrue);
        }

        // Unblock so _run() finishes.
        for (final c in completers) {
          c.complete(const MontyComplete(result: MontyResult(usage: _usage)));
        }
      });

      test('is idempotent', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );

        await plugin.onDispose();
        await plugin.onDispose();
      });

      test('completed children are not cancelled again', () async {
        final mock = _completingMock();
        final plugin = SandboxPlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        await plugin.onDispose();

        expect(mock.isDisposed, isTrue);
      });
    });

    group('child plugin wiring', () {
      test('child gets plugins from factory', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          childPluginRegistryFactory: (_) async {
            final registry = PluginRegistry()
              ..register(
                _TestPlugin(
                  namespace: 'helper',
                  functions: [
                    HostFunction(
                      schema: const HostFunctionSchema(
                        name: 'helper_ping',
                        description: 'Ping.',
                      ),
                      handler: (args) async => 'pong',
                    ),
                  ],
                ),
              );
            return registry;
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': 'helper_ping()'});

        await await_({'handle': handle! as int});
      });

      test(
        'childPluginRegistryFactory takes precedence over parentPlugins',
        () async {
          var factoryCalled = false;
          final parentPlugin = _InheritablePlugin(namespace: 'parent');
          final plugin = SandboxPlugin(
            platformFactory: () async => _completingMock(),
            parentPlugins: [parentPlugin],
            childPluginRegistryFactory: (_) async {
              factoryCalled = true;
              // Explicit factory returns empty registry —
              // no parent inheritance.
              return PluginRegistry();
            },
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await spawn({'code': '42'});

          expect(factoryCalled, isTrue);
        },
      );
    });

    group('createChildInstance inheritance', () {
      test('children inherit plugins that opt in', () async {
        final parentPlugin = _InheritablePlugin(namespace: 'shared');
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          parentPlugins: [parentPlugin],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        // Child should have shared_ping available.
        final handle = await spawn({'code': 'shared_ping()'});
        await await_({'handle': handle! as int});
      });

      test('children do not inherit plugins that return null', () async {
        // _TestPlugin does not override createChildInstance — returns null.
        // Verify _buildInheritedRegistry produces null (no plugins to inherit),
        // so children only get introspection builtins.
        final parentPlugin = _TestPlugin(
          namespace: 'noinherit',
          functions: [
            HostFunction(
              schema: const HostFunctionSchema(
                name: 'noinherit_ping',
                description: 'Ping.',
              ),
              handler: (args) async => 'pong',
            ),
          ],
        );

        // With only non-inheritable plugins, behavior is the same as no
        // parentPlugins — child spawns with only introspection builtins.
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          parentPlugins: [parentPlugin],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        // Child runs fine — just no extra plugins.
        final handle = await spawn({'code': '42'});
        final result = await await_({'handle': handle! as int});
        expect(result, isNull); // Mock returns null value.
      });

      test('SandboxPlugin is never inherited to children', () async {
        // Even if SandboxPlugin somehow ended up in parentPlugins,
        // _buildInheritedRegistry skips it.
        final innerSandbox = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          parentPlugins: [innerSandbox],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        // Should work fine — no plugins inherited, just introspection.
        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});
      });

      test(
        'empty parentPlugins with no factory gives children only builtins',
        () async {
          final plugin = SandboxPlugin(
            platformFactory: () async => _completingMock(),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');

          // list_functions is an introspection builtin — always available.
          final handle = await spawn({'code': 'list_functions()'});
          await await_({'handle': handle! as int});
        },
      );

      test(
        'createChildInstance returning SandboxPlugin throws StateError',
        () async {
          final badPlugin = _ReturnsSandboxPlugin();
          final plugin = SandboxPlugin(
            platformFactory: () async => _completingMock(),
            parentPlugins: [badPlugin],
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await expectLater(spawn({'code': '42'}), throwsStateError);
        },
      );

      test('spawn cleans up platform on factory failure', () async {
        late MockMontyPlatform createdMock;
        final plugin = SandboxPlugin(
          platformFactory: () async {
            return createdMock = _completingMock();
          },
          childPluginRegistryFactory: (_) async {
            throw StateError('factory boom');
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '42'}), throwsStateError);
        expect(createdMock.isDisposed, isTrue);
      });
    });

    group('ChildSpawnContext threading', () {
      test(
        'context flows to createChildInstance with correct childId',
        () async {
          ChildSpawnContext? capturedContext;
          final plugin = SandboxPlugin(
            platformFactory: () async => _completingMock(),
            parentPlugins: [
              _ContextCapturingPlugin(
                onContext: (ctx) => capturedContext = ctx,
              ),
            ],
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');

          final handle = await spawn({'code': '42'});
          await await_({'handle': handle! as int});

          expect(capturedContext, isNotNull);
          expect(capturedContext!.childId, 0);
        },
      );

      test('null sandboxBaseDir gives null workingDirectory', () async {
        ChildSpawnContext? capturedContext;
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          parentPlugins: [
            _ContextCapturingPlugin(onContext: (ctx) => capturedContext = ctx),
          ],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});

        expect(capturedContext, isNotNull);
        expect(capturedContext!.workingDirectory, isNull);
      });

      test('sandboxBaseDir produces correct workingDirectory', () async {
        ChildSpawnContext? capturedContext;
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          sandboxBaseDir: '/tmp/test',
          parentPlugins: [
            _ContextCapturingPlugin(onContext: (ctx) => capturedContext = ctx),
          ],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});

        expect(capturedContext, isNotNull);
        expect(
          capturedContext!.workingDirectory,
          '/tmp/test/.sandboxes/child_0',
        );
      });

      test('sequential spawns get incrementing paths', () async {
        final contexts = <ChildSpawnContext>[];
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          sandboxBaseDir: '/data',
          parentPlugins: [_ContextCapturingPlugin(onContext: contexts.add)],
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final h0 = (await spawn({'code': '1'}))! as int;
        final h1 = (await spawn({'code': '2'}))! as int;
        await await_({'handle': h0});
        await await_({'handle': h1});

        expect(contexts, hasLength(2));
        expect(contexts[0].childId, 0);
        expect(contexts[0].workingDirectory, '/data/.sandboxes/child_0');
        expect(contexts[1].childId, 1);
        expect(contexts[1].workingDirectory, '/data/.sandboxes/child_1');
      });

      test('factory receives ChildSpawnContext', () async {
        ChildSpawnContext? factoryContext;
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          sandboxBaseDir: '/base',
          childPluginRegistryFactory: (ctx) async {
            factoryContext = ctx;
            return null;
          },
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});

        expect(factoryContext, isNotNull);
        expect(factoryContext!.childId, 0);
        expect(factoryContext!.workingDirectory, '/base/.sandboxes/child_0');
      });
    });

    group('structured logging', () {
      late MemorySink sink;
      late Logger logger;
      late LogLevel previousLevel;

      setUp(() {
        sink = MemorySink();
        previousLevel = LogManager.instance.minimumLevel;
        LogManager.instance
          ..addSink(sink)
          ..minimumLevel = LogLevel.trace;
        logger = LogManager.instance.getLogger('SandboxPlugin.test');
      });

      tearDown(() {
        LogManager.instance
          ..removeSink(sink)
          ..minimumLevel = previousLevel;
      });

      test('spawn logs info with childId and depth', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});

        final spawnRecord = sink.records.firstWhere(
          (r) => r.message == 'Child spawned',
        );
        expect(spawnRecord.level, LogLevel.info);
        expect(spawnRecord.attributes['childId'], 0);
        expect(spawnRecord.attributes['depth'], 0);
      });

      test('spawn logs debug for bridge creation with codeLength', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'x = 42'});

        final bridgeRecord = sink.records.firstWhere(
          (r) => r.message == 'Child bridge created',
        );
        expect(bridgeRecord.level, LogLevel.debug);
        expect(bridgeRecord.attributes['codeLength'], 6);
      });

      test('completion logs info with childId', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '42'});
        await await_({'handle': handle! as int});

        final completedRecord = sink.records.firstWhere(
          (r) => r.message == 'Child completed',
        );
        expect(completedRecord.level, LogLevel.info);
        expect(completedRecord.attributes['childId'], 0);
      });

      test('failure logs warning with childId and error', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _failingMock('NameError: x'),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': 'x'});
        try {
          await await_({'handle': handle! as int});
        } on Exception {
          // Expected.
        }

        final failRecord = sink.records.firstWhere(
          (r) => r.message == 'Child failed',
        );
        expect(failRecord.level, LogLevel.warning);
        expect(failRecord.attributes['childId'], 0);
        expect(failRecord.attributes['error'], contains('NameError'));
      });

      test('cancel logs info with childId', () async {
        final startCompleter = Completer<MontyProgress>();
        final plugin = SandboxPlugin(
          platformFactory: () async => _SlowMockPlatform(startCompleter.future),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final cancel = _findHandler(plugin, 'sandbox_cancel');

        final handle = await spawn({'code': 'wait()'});
        await cancel({'handle': handle! as int});

        final cancelRecord = sink.records.firstWhere(
          (r) => r.message == 'Cancelling child',
        );
        expect(cancelRecord.level, LogLevel.info);
        expect(cancelRecord.attributes['childId'], 0);

        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
        // Let microtasks settle so onDone fires before tearDown removes sink.
        await Future<void>.delayed(Duration.zero);
      });

      test('free logs debug with childId', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');

        final handle = await spawn({'code': '1'});
        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        final freeRecord = sink.records.firstWhere(
          (r) => r.message == 'Child freed',
        );
        expect(freeRecord.level, LogLevel.debug);
        expect(freeRecord.attributes['childId'], 0);
      });

      test('dispose logs info with child counts', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '1'});
        await await_({'handle': handle! as int});
        await plugin.onDispose();

        final disposeRecord = sink.records.firstWhere(
          (r) => r.message == 'Disposing SandboxPlugin',
        );
        expect(disposeRecord.level, LogLevel.info);
        expect(disposeRecord.attributes['totalChildren'], 1);
        expect(disposeRecord.attributes['aliveChildren'], 0);
      });

      test('depth limit rejection logs warning', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          maxDepth: 2,
          currentDepth: 2,
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        final warnRecord = sink.records.firstWhere(
          (r) => r.message == 'Spawn rejected: depth limit',
        );
        expect(warnRecord.level, LogLevel.warning);
        expect(warnRecord.attributes['currentDepth'], 2);
        expect(warnRecord.attributes['maxDepth'], 2);
      });

      test('concurrency limit rejection logs warning', () async {
        final completers = <Completer<MontyProgress>>[];
        final plugin = SandboxPlugin(
          platformFactory: () async {
            final c = Completer<MontyProgress>();
            completers.add(c);
            return _SlowMockPlatform(c.future);
          },
          maxChildren: 1,
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'a'});

        await expectLater(spawn({'code': 'b'}), throwsStateError);

        final warnRecord = sink.records.firstWhere(
          (r) => r.message == 'Spawn rejected: concurrency limit',
        );
        expect(warnRecord.level, LogLevel.warning);
        expect(warnRecord.attributes['alive'], 1);
        expect(warnRecord.attributes['maxChildren'], 1);

        for (final c in completers) {
          c.complete(const MontyComplete(result: MontyResult(usage: _usage)));
        }
        await plugin.onDispose();
      });

      test('factory failure logs error with phase=factory', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          childPluginRegistryFactory: (_) async {
            throw StateError('factory boom');
          },
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        final errorRecord = sink.records.firstWhere(
          (r) => r.message == 'Child plugin factory failed',
        );
        expect(errorRecord.level, LogLevel.error);
        expect(errorRecord.attributes['phase'], 'factory');
        expect(errorRecord.error, isA<StateError>());
        expect(errorRecord.stackTrace, isNotNull);
      });

      test('child cleanup error is logged as warning', () async {
        // Use a platform whose dispose throws.
        final plugin = SandboxPlugin(
          platformFactory: () async => _DisposeBoomMock(),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '1'});
        await await_({'handle': handle! as int});

        final cleanupWarnings = sink.records.where(
          (r) => r.message == 'Child cleanup error (swallowed)',
        );
        expect(cleanupWarnings, isNotEmpty);
        expect(cleanupWarnings.first.level, LogLevel.warning);
        expect(cleanupWarnings.first.attributes['childId'], 0);
      });

      test('plugin attachment logs debug with plugin count', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          childPluginRegistryFactory: (_) async {
            final registry = PluginRegistry()
              ..register(
                _TestPlugin(
                  namespace: 'helper',
                  functions: [
                    HostFunction(
                      schema: const HostFunctionSchema(
                        name: 'helper_ping',
                        description: 'Ping.',
                      ),
                      handler: (args) async => 'pong',
                    ),
                  ],
                ),
              );
            return registry;
          },
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '1'});
        await await_({'handle': handle! as int});

        final attachRecord = sink.records.firstWhere(
          (r) => r.message == 'Child plugins attached',
        );
        expect(attachRecord.level, LogLevel.debug);
        expect(attachRecord.attributes['pluginCount'], 1);
      });

      test('inheritance failure logs error with phase=inheritance', () async {
        final badPlugin = _ReturnsSandboxPlugin();
        final plugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
          parentPlugins: [badPlugin],
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        final errorRecord = sink.records.firstWhere(
          (r) => r.message == 'Child plugin inheritance failed',
        );
        expect(errorRecord.level, LogLevel.error);
        expect(errorRecord.attributes['phase'], 'inheritance');
        expect(errorRecord.error, isA<StateError>());
      });

      test(
        'attachTo failure logs error with phase=attachTo and pluginCount',
        () async {
          final plugin = SandboxPlugin(
            platformFactory: () async => _completingMock(),
            childPluginRegistryFactory: (_) async {
              final registry = PluginRegistry()..register(_AttachBoomPlugin());
              return registry;
            },
          )..logger = StructLogBridgeLogger(logger, LogManager.instance);
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await expectLater(spawn({'code': '1'}), throwsStateError);

          final errorRecord = sink.records.firstWhere(
            (r) => r.message == 'Child plugin attachment failed',
          );
          expect(errorRecord.level, LogLevel.error);
          expect(errorRecord.attributes['phase'], 'attachTo');
          expect(errorRecord.attributes['pluginCount'], 1);
          expect(errorRecord.error, isA<StateError>());
        },
      );

      test('factory failure still cleans up platform and bridge', () async {
        late MockMontyPlatform createdMock;
        final plugin = SandboxPlugin(
          platformFactory: () async {
            return createdMock = _completingMock();
          },
          childPluginRegistryFactory: (_) async {
            throw StateError('factory boom');
          },
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        expect(createdMock.isDisposed, isTrue);
      });

      test('error message is truncated in log attributes', () async {
        final longError = 'E' * 300;
        final plugin = SandboxPlugin(
          platformFactory: () async => _failingMock(longError),
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': 'x'});
        try {
          await await_({'handle': handle! as int});
        } on Exception {
          // Expected.
        }

        final failRecord = sink.records.firstWhere(
          (r) => r.message == 'Child failed',
        );
        final logged = failRecord.attributes['error']! as String;
        expect(logged.length, lessThanOrEqualTo(201)); // 200 + ellipsis
        expect(logged, endsWith('…'));
      });

      test('platformFactory failure logs error with phase=platform', () async {
        final plugin = SandboxPlugin(
          platformFactory: () async {
            throw StateError('platform creation boom');
          },
        )..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        final errorRecord = sink.records.firstWhere(
          (r) => r.message == 'Child platform creation failed',
        );
        expect(errorRecord.level, LogLevel.error);
        expect(errorRecord.attributes['phase'], 'platform');
        expect(errorRecord.error, isA<StateError>());
      });

      test('default logger is NullBridgeLogger', () {
        final defaultPlugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        expect(defaultPlugin.logger, isA<NullBridgeLogger>());
      });
    });
  });
}

/// Finds a handler by function name from the plugin's function list.
HostFunctionHandler _findHandler(SandboxPlugin plugin, String name) {
  return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
}

/// Test plugin that opts into child inheritance via [createChildInstance].
class _InheritablePlugin extends MontyPlugin {
  _InheritablePlugin({required this.namespace});

  @override
  final String namespace;

  @override
  final String? systemPromptContext = null;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: HostFunctionSchema(
        name: '${namespace}_ping',
        description: 'Ping.',
      ),
      handler: (args) async => 'pong',
    ),
  ];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) =>
      _InheritablePlugin(namespace: namespace);
}

/// Plugin whose [createChildInstance] returns an [SandboxPlugin].
///
/// Used to verify that the inheritance guard rejects such plugins.
class _ReturnsSandboxPlugin extends MontyPlugin {
  @override
  String get namespace => 'bad';

  @override
  final String? systemPromptContext = null;

  @override
  List<HostFunction> get functions => [];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) =>
      SandboxPlugin(platformFactory: () async => MockMontyPlatform());
}

/// Simple test plugin for child wiring tests.
class _TestPlugin extends MontyPlugin {
  _TestPlugin({required this.namespace, required this.functions});

  @override
  final String namespace;

  @override
  final String? systemPromptContext = null;

  @override
  final List<HostFunction> functions;
}

/// Plugin that captures the [ChildSpawnContext] passed to
/// [MontyPlugin.createChildInstance].
class _ContextCapturingPlugin extends MontyPlugin {
  _ContextCapturingPlugin({required this.onContext});

  final void Function(ChildSpawnContext) onContext;

  @override
  String get namespace => 'ctx_capture';

  @override
  final String? systemPromptContext = null;

  @override
  List<HostFunction> get functions => [];

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    if (context != null) onContext(context);
    return _TestPlugin(namespace: 'ctx_child', functions: []);
  }
}

/// A [MontyPlatform] that completes normally but throws on [dispose].
///
/// Used to test that cleanup errors in onDone are logged rather than swallowed
/// silently.
class _DisposeBoomMock extends MontyPlatform {
  bool _disposeCallCount = false;

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async => const MontyComplete(
    result: MontyResult(
      usage: MontyResourceUsage(
        memoryBytesUsed: 1024,
        timeElapsedMs: 10,
        stackDepthUsed: 5,
      ),
    ),
  );

  @override
  Future<MontyProgress> resume(Object? returnValue) async =>
      throw StateError('Unexpected resume');

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async =>
      throw StateError('Unexpected resumeWithError');

  @override
  Future<void> dispose() async {
    if (_disposeCallCount) return;
    _disposeCallCount = true;
    throw StateError('dispose boom');
  }
}

/// Plugin whose [onRegister] throws, simulating an attachTo failure.
class _AttachBoomPlugin extends MontyPlugin {
  @override
  String get namespace => 'boom';

  @override
  final String? systemPromptContext = null;

  @override
  List<HostFunction> get functions => [];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    throw StateError('attachTo boom');
  }
}

/// A [MontyPlatform] whose [start] hangs until a [Completer] is completed.
///
/// This keeps the child bridge "running" so tests can observe alive state,
/// cancel behaviour, and concurrency limits before the child finishes.
class _SlowMockPlatform extends MontyPlatform {
  _SlowMockPlatform(this._startFuture);

  final Future<MontyProgress> _startFuture;

  /// Whether [dispose] has been called.
  bool isDisposed = false;

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) => _startFuture;

  @override
  Future<MontyProgress> resume(Object? returnValue) async =>
      throw StateError('Unexpected resume on _SlowMockPlatform');

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async =>
      throw StateError('Unexpected resumeWithError on _SlowMockPlatform');

  @override
  Future<void> dispose() async {
    isDisposed = true;
  }
}

/// A [MontyPlatform] whose [start] throws a non-Python infrastructure error.
///
/// Used to verify that infrastructure errors produce [ChildSandboxException]
/// with `exception == null`.
class _InfraErrorMock extends MontyPlatform {
  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async => throw StateError('infra boom');

  @override
  Future<MontyProgress> resume(Object? returnValue) async =>
      throw StateError('Unexpected resume on _InfraErrorMock');

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async =>
      throw StateError('Unexpected resumeWithError on _InfraErrorMock');

  @override
  Future<void> dispose() async {}
}
