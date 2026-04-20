import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty/src/host_context.dart';
import 'package:signals_core/signals_core.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

final _testCtx = HostContext(emit: (_) {}, executionId: 'test');

const _usage = MontyResourceUsage(
  memoryBytesUsed: 1024,
  timeElapsedMs: 10,
  stackDepthUsed: 5,
);

/// Creates a [MockMontyPlatform] that runs code to completion immediately.
MockMontyPlatform _completingMock() {
  return MockMontyPlatform()..enqueueProgress(
    const MontyComplete(
      result: MontyResult(value: MontyNone(), usage: _usage),
    ),
  );
}

/// Creates a [MockMontyPlatform] that completes with [value] and [printOutput].
MockMontyPlatform _completingMockWithResult({
  MontyValue? value,
  String? printOutput,
}) {
  return MockMontyPlatform()..enqueueProgress(
    MontyComplete(
      result: MontyResult(
        value: value ?? const MontyNone(),
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
        value: const MontyNone(),
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
        value: const MontyNone(),
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

/// Attaches [plugin] to a minimal bridge so `registry` is injected.
///
/// Many tests exercise handlers directly (via [_findHandler]) but
/// `sandbox_spawn` reaches into `registry.spawnChild(...)` — that field is
/// injected by [PluginRegistry.attachTo], so the plugin must be attached first.
Future<SandboxPlugin> _attachedPlugin(SandboxPlugin plugin) async {
  final registry = PluginRegistry()..register(plugin);
  final bridge = DefaultMontyBridge(platform: MockMontyPlatform());
  await registry.attachTo(bridge);
  return plugin;
}

void main() {
  group('SandboxPlugin', () {
    group('metadata', () {
      test('namespace is "sandbox"', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => MockMontyPlatform(),
          ),
        );
        expect(plugin.namespace, 'sandbox');
      });

      test('has system prompt context', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => MockMontyPlatform(),
          ),
        );
        expect(plugin.systemPromptContext, isNotNull);
        expect(plugin.systemPromptContext, contains('sandboxed'));
      });

      test('provides 7 host functions', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => MockMontyPlatform(),
          ),
        );
        expect(plugin.functions, hasLength(7));
      });

      test('all function names start with sandbox_', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => MockMontyPlatform(),
          ),
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

      test('sandbox_spawn.code declares python render hint', () {
        final plugin = SandboxPlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        final spawn = plugin.functions.firstWhere(
          (f) => f.schema.name == 'sandbox_spawn',
        );
        final schema = spawn.schema.toJsonSchema();
        final properties = schema['properties']! as Map<String, Object?>;
        final code = properties['code']! as Map<String, Object?>;
        expect(code['x-render-as'], 'python');
      });
    });

    group('sandbox_spawn', () {
      test('returns an integer handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final handle = await spawn!({'code': 'x = 1'});

        expect(handle, isA<int>());
        expect(handle, 0);
      });

      test('sequential spawns return incrementing handles', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final h0 = await spawn!({'code': 'a'});
        final h1 = await spawn!({'code': 'b'});
        final h2 = await spawn!({'code': 'c'});

        expect(h0, 0);
        expect(h1, 1);
        expect(h2, 2);
      });

      test('passes code to child platform start()', () async {
        final mock = _completingMock();
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': 'print("hello")'});

        // The bridge wraps code with print preamble, so check the mock
        // received something containing our code.
        expect(mock.history.lastStartCode, contains('print("hello")'));
      });

      test('child platform is disposed after completion', () async {
        final mock = _completingMock();
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': '42'});

        await await_!({'handle': handle! as int});

        expect(mock.isDisposed, isTrue);
      });

      test('applies timeout_ms and memory_bytes to child limits', () async {
        final mock = _completingMock();
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': '1', 'timeout_ms': 5000, 'memory_bytes': 1048576});

        // Give the bridge time to call start().
        await Future<void>.delayed(Duration.zero);

        expect(mock.history.lastStartLimits, isNotNull);
        expect(mock.history.lastStartLimits!.timeoutMs, 5000);
        expect(mock.history.lastStartLimits!.memoryBytes, 1048576);
      });

      test('throws StateError when disposed', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        await plugin.onDispose();
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        expect(
          () => spawn!({'code': '1'}),
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': 'x = 1'});
        final result = await await_!({'handle': handle! as int});

        expect(result, isNull);
      });

      test('returns child return value', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async =>
                _completingMockWithResult(value: const MontyInt(42)),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': '42'});
        final result = await await_!({'handle': handle! as int});

        expect(result, 42);
      });

      test('throws ChildSandboxException for failed child', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _failingMock('NameError: x'),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': 'x'});

        expect(
          () => await_!({'handle': handle! as int}),
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
          final plugin = await _attachedPlugin(
            SandboxPlugin(
              platformFactory: () async => _failingMockStructured(
                message: 'NameError: undefined_var',
                filename: '<code>',
                lineNumber: 7,
                columnNumber: 4,
                excType: 'NameError',
              ),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn!({'code': 'undefined_var'});

          try {
            await await_!({'handle': handle! as int});
            fail('Expected ChildSandboxException');
          } on ChildSandboxException catch (e) {
            expect(e.childId, handle);
            expect(e.message, contains('NameError'));
            expect(e.exception, isNotNull);
            expect(e.exception!.excType, 'NameError');
            expect(e.exception!.filename, '<code>');
            // Line number is the raw Monty value — no preamble offset applied.
            expect(e.exception!.lineNumber, 7);
            expect(e.exception!.columnNumber, 4);
          }
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final await_ = _findHandler(plugin, 'sandbox_await');

        expect(() => await_!({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_await_all', () {
      test('returns results for all children', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');
        final h0 = await spawn!({'code': 'a'});
        final h1 = await spawn!({'code': 'b'});

        final results = await awaitAll({
          'handles': <Object?>[h0, h1],
        });

        expect(results, isA<List<Object?>>());
        expect(results! as List<Object?>, hasLength(2));
      });

      test('throws if any child fails', () async {
        var callCount = 0;
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async {
              callCount++;
              if (callCount == 2) return _failingMock('boom');
              return _completingMock();
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');
        final h0 = await spawn!({'code': 'ok'});
        final h1 = await spawn!({'code': 'fail'});

        expect(
          () => awaitAll({
            'handles': <Object?>[h0, h1],
          }),
          throwsA(isA<ChildSandboxException>()),
        );
      });

      test('throws ArgumentError for unknown handle in list', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
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

        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn!({'code': '1'});

        // Bridge is waiting for start() to complete — child is alive.
        final alive = await isAlive({'handle': handle! as int});
        expect(alive, isTrue);

        // Unblock and clean up.
        startCompleter.complete(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );
        await plugin.onDispose();
      });

      test('returns false after child completes', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn!({'code': '1'});

        await await_!({'handle': handle! as int});

        final alive = await isAlive({'handle': handle as int});
        expect(alive, isFalse);
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');

        expect(() => isAlive({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_get_output', () {
      test('returns print output from completed child', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async =>
                _completingMockWithResult(printOutput: 'hello world\n'),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn!({'code': 'print("hello world")'});

        await await_!({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, 'hello world\n');
      });

      test('returns null when child had no print output', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn!({'code': '42'});

        await await_!({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, isNull);
      });

      test('throws StateError when child is still running', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn!({'code': 'print("hi")'});

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
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );
        await plugin.onDispose();
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
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
          final plugin = await _attachedPlugin(
            SandboxPlugin(
              platformFactory: () async {
                callCount++;
                return _completingMockWithResult(
                  value: MontyInt(callCount),
                  printOutput: 'output_$callCount\n',
                );
              },
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final gather = _findHandler(plugin, 'sandbox_gather');

          final h0 = (await spawn!({'code': 'a'}))! as int;
          final h1 = (await spawn!({'code': 'b'}))! as int;

          final result =
              (await gather!({
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async {
              callCount++;
              return _completingMockWithResult(value: MontyInt(callCount * 10));
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn!({'code': 'a'}))! as int;
        final h1 = (await spawn!({'code': 'b'}))! as int;
        final h2 = (await spawn!({'code': 'c'}))! as int;

        // Request in reverse order.
        final result =
            (await gather!({
                  'handles': [h2, h0, h1],
                }))!
                as List<Object?>;

        expect(result, hasLength(3));
        expect((result[0]! as Map)['handle'], h2);
        expect((result[1]! as Map)['handle'], h0);
        expect((result[2]! as Map)['handle'], h1);
      });

      test('handles null printOutput (child with no print)', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async =>
                _completingMockWithResult(value: const MontyInt(42)),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn!({'code': 'a'}))! as int;

        final result =
            (await gather!({
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async {
              callCount++;
              if (callCount == 2) return _failingMock('child failed');
              return _completingMockWithResult(value: MontyInt(callCount));
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn!({'code': 'a'}))! as int;
        final h1 = (await spawn!({'code': 'b'}))! as int;

        expect(
          () => gather!({
            'handles': [h0, h1],
          }),
          throwsA(isA<ChildSandboxException>()),
        );
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final gather = _findHandler(plugin, 'sandbox_gather');

        expect(
          () => gather!({
            'handles': [999],
          }),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('works with single handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMockWithResult(
              value: const MontyString('solo'),
              printOutput: 'hi\n',
            ),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final gather = _findHandler(plugin, 'sandbox_gather');

        final h0 = (await spawn!({'code': 'a'}))! as int;

        final result =
            (await gather!({
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn!({'code': '1'});

        await await_!({'handle': handle! as int});
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn!({'code': '1'});

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
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );
        await plugin.onDispose();
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final free = _findHandler(plugin, 'sandbox_free');

        expect(() => free({'handle': 999}), throwsA(isA<ArgumentError>()));
      });

      test('double free throws ArgumentError', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn!({'code': '1'});

        await await_!({'handle': handle! as int});
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
                value: MontyNone(),
                error: MontyException(message: 'NameError: x'),
                usage: _usage,
                printOutput: 'debug line\n',
              ),
            ),
          );
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final getOutput = _findHandler(plugin, 'sandbox_get_output');
        final handle = await spawn!({'code': 'print("debug line"); x'});

        // Await will throw because the child failed.
        await expectLater(
          () => await_!({'handle': handle! as int}),
          throwsA(isA<ChildSandboxException>()),
        );

        final output = await getOutput({'handle': handle! as int});
        expect(output, contains('debug'));
      });
    });

    group('depth limiting', () {
      test('rejects spawn when currentDepth >= maxDepth', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
            maxDepth: 2,
            currentDepth: 2,
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        expect(
          () => spawn!({'code': '1'}),
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
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
            currentDepth: 1,
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final handle = await spawn!({'code': '1'});
        expect(handle, isA<int>());
      });
    });

    group('concurrency limiting', () {
      test('rejects spawn when maxChildren reached', () async {
        final completers = <Completer<MontyProgress>>[];
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async {
              final c = Completer<MontyProgress>();
              completers.add(c);
              return _SlowMockPlatform(c.future);
            },
            maxChildren: 2,
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': 'a'});
        await spawn!({'code': 'b'});

        expect(
          () => spawn!({'code': 'c'}),
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
          c.complete(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );
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
        const e = ChildSandboxException(childId: 0, message: 'disposed');
        expect(e.exception, isNull);
      });

      test('infrastructure error produces null exception field', () async {
        // A platform whose start() throws a non-MontyException error.
        // The bridge catches it via `on Object` and emits BridgeRunError
        // without a MontyException.
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _InfraErrorMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': '1'});

        expect(
          () => await_!({'handle': handle! as int}),
          throwsA(
            isA<ChildSandboxException>()
                .having((e) => e.exception, 'exception', isNull)
                .having((e) => e.message, 'message', contains('infra boom')),
          ),
        );
      });
    });

    group('onDispose', () {
      test('tears down all living children', () async {
        final completers = <Completer<MontyProgress>>[];
        final mocks = <_SlowMockPlatform>[];
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async {
              final c = Completer<MontyProgress>();
              completers.add(c);
              final m = _SlowMockPlatform(c.future);
              mocks.add(m);
              return m;
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': 'a'});
        await spawn!({'code': 'b'});

        await plugin.onDispose();

        for (final mock in mocks) {
          expect(mock.isDisposed, isTrue);
        }

        // Unblock so _run() finishes.
        for (final c in completers) {
          c.complete(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );
        }
      });

      test('is idempotent', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );

        await plugin.onDispose();
        await plugin.onDispose();
      });

      test(
        'dispose during child creation cleans up and spawn throws',
        () async {
          // Regression test for #264 — post-await _disposed check in
          // _handleSpawn.
          //
          // Without the fix, the child platform would be created and added to
          // _children after onDispose() returned, leaking it permanently.
          // With the fix, the platform is disposed and spawn throws StateError.
          final platformCompleter = Completer<MontyPlatform>();
          late _SlowMockPlatform createdPlatform;

          final plugin = await _attachedPlugin(
            SandboxPlugin(
              platformFactory: () async {
                createdPlatform = _SlowMockPlatform(
                  // Platform.start() never returns — child stays alive while we
                  // test the race.
                  Completer<MontyProgress>().future,
                );
                platformCompleter.complete(createdPlatform);

                return createdPlatform;
              },
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          // Start spawn — hangs inside _createChildPlatformAndBridge at the
          // await platformFactory() call.
          final spawnFuture = spawn!({'code': '1'});

          // Wait until the factory has been entered (platform is now being
          // created) then dispose the plugin while spawn is in flight.
          await platformCompleter.future;
          await plugin.onDispose();

          // spawn should throw StateError and the created platform must be
          // disposed by the post-await cleanup.
          await expectLater(spawnFuture, throwsStateError);
          expect(
            createdPlatform.isDisposed,
            isTrue,
            reason: 'platform created during disposed spawn must be torn down',
          );
          expect(
            plugin.childrenSignal.value,
            isEmpty,
            reason: 'disposed-mid-spawn child must not appear in children',
          );
        },
      );

      test('completed children are not torn down again', () async {
        final mock = _completingMock();
        final plugin = await _attachedPlugin(
          SandboxPlugin(platformFactory: () async => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn!({'code': '1'});

        await await_!({'handle': handle! as int});

        await plugin.onDispose();

        expect(mock.isDisposed, isTrue);
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
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn!({'code': '42'});
        await await_!({'handle': handle! as int});

        final spawnRecord = sink.records.firstWhere(
          (r) => r.message == 'Child spawned',
        );
        expect(spawnRecord.level, LogLevel.info);
        expect(spawnRecord.attributes['childId'], 0);
        expect(spawnRecord.attributes['depth'], 0);
      });

      test('spawn logs debug for bridge creation with codeLength', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': 'x = 42'});

        final bridgeRecord = sink.records.firstWhere(
          (r) => r.message == 'Child bridge created',
        );
        expect(bridgeRecord.level, LogLevel.debug);
        expect(bridgeRecord.attributes['codeLength'], 6);
      });

      test('completion logs info with childId', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn!({'code': '42'});
        await await_!({'handle': handle! as int});

        final completedRecord = sink.records.firstWhere(
          (r) => r.message == 'Child completed',
        );
        expect(completedRecord.level, LogLevel.info);
        expect(completedRecord.attributes['childId'], 0);
      });

      test('failure logs debug with childId and error', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _failingMock('NameError: x'),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn!({'code': 'x'});
        try {
          await await_!({'handle': handle! as int});
        } on Exception {
          // Expected.
        }

        final failRecord = sink.records.firstWhere(
          (r) => r.message == 'Child failed',
        );
        expect(failRecord.level, LogLevel.debug);
        expect(failRecord.attributes['childId'], 0);
        expect(failRecord.attributes['error'], contains('NameError'));
      });

      test('free logs debug with childId', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');

        final handle = await spawn!({'code': '1'});
        await await_!({'handle': handle! as int});
        await free({'handle': handle as int});

        final freeRecord = sink.records.firstWhere(
          (r) => r.message == 'Child freed',
        );
        expect(freeRecord.level, LogLevel.debug);
        expect(freeRecord.attributes['childId'], 0);
      });

      test('dispose logs info with child counts', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn!({'code': '1'});
        await await_!({'handle': handle! as int});
        await plugin.onDispose();

        final disposeRecord = sink.records.firstWhere(
          (r) => r.message == 'Disposing SandboxPlugin',
        );
        expect(disposeRecord.level, LogLevel.info);
        expect(disposeRecord.attributes['totalChildren'], 1);
        expect(disposeRecord.attributes['aliveChildren'], 0);
      });

      test('depth limit rejection logs warning', () async {
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _completingMock(),
                  maxDepth: 2,
                  currentDepth: 2,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn!({'code': '1'}), throwsStateError);

        final warnRecord = sink.records.firstWhere(
          (r) => r.message == 'Spawn rejected: depth limit',
        );
        expect(warnRecord.level, LogLevel.warning);
        expect(warnRecord.attributes['currentDepth'], 2);
        expect(warnRecord.attributes['maxDepth'], 2);
      });

      test('concurrency limit rejection logs warning', () async {
        final completers = <Completer<MontyProgress>>[];
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async {
                    final c = Completer<MontyProgress>();
                    completers.add(c);
                    return _SlowMockPlatform(c.future);
                  },
                  maxChildren: 1,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn!({'code': 'a'});

        await expectLater(spawn!({'code': 'b'}), throwsStateError);

        final warnRecord = sink.records.firstWhere(
          (r) => r.message == 'Spawn rejected: concurrency limit',
        );
        expect(warnRecord.level, LogLevel.warning);
        expect(warnRecord.attributes['alive'], 1);
        expect(warnRecord.attributes['maxChildren'], 1);

        for (final c in completers) {
          c.complete(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );
        }
        await plugin.onDispose();
      });

      test('error message is truncated in log attributes', () async {
        final longError = 'E' * 300;
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async => _failingMock(longError),
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn!({'code': 'x'});
        try {
          await await_!({'handle': handle! as int});
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
        final plugin =
            await _attachedPlugin(
                SandboxPlugin(
                  platformFactory: () async {
                    throw StateError('platform creation boom');
                  },
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn!({'code': '1'}), throwsStateError);

        final errorRecord = sink.records.firstWhere(
          (r) => r.message == 'Child platform creation failed',
        );
        expect(errorRecord.level, LogLevel.error);
        expect(errorRecord.attributes['phase'], 'platform');
        expect(errorRecord.error, isA<StateError>());
      });

      test('default logger is NullBridgeLogger before attach', () {
        final defaultPlugin = SandboxPlugin(
          platformFactory: () async => _completingMock(),
        );
        expect(defaultPlugin.logger, isA<NullBridgeLogger>());
      });
    });

    group('signals', () {
      test('childrenSignal is empty before any spawn', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        expect(plugin.childrenSignal.value, isEmpty);
      });

      test('aliveCountSignal is 0 before any spawn', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        expect(plugin.aliveCountSignal.value, 0);
      });

      test(
        'childrenSignal contains ChildRunning immediately after spawn',
        () async {
          final plugin = await _attachedPlugin(
            SandboxPlugin(
              platformFactory: () async => _completingMock(),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          final handle = (await spawn!({'code': 'x = 1'}))! as int;

          expect(
            plugin.childrenSignal.value,
            containsPair(handle, isA<ChildRunning>()),
          );
          expect(plugin.aliveCountSignal.value, 1);
        },
      );

      test(
        'childrenSignal updates to ChildCompleted after child finishes',
        () async {
          final plugin = await _attachedPlugin(
            SandboxPlugin(
              platformFactory: () async => _completingMockWithResult(
                value: const MontyInt(42),
              ),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');

          final handle = (await spawn!({'code': 'x = 42'}))! as int;
          await await_!({'handle': handle});

          expect(
            plugin.childrenSignal.value[handle],
            isA<ChildCompleted>(),
          );
          expect(plugin.aliveCountSignal.value, 0);
        },
      );

      test('ChildCompleted carries the return value', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMockWithResult(
              value: const MontyInt(7),
            ),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = (await spawn!({'code': 'x = 7'}))! as int;
        await await_!({'handle': handle});

        final state = plugin.childrenSignal.value[handle]! as ChildCompleted;
        expect(state.value, 7);
      });

      test('childrenSignal updates to ChildFailed when child errors', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _failingMock('boom'),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle =
            (await spawn!({'code': 'raise ValueError("boom")'}))! as int;
        await await_!({'handle': handle}).catchError((_) => null);

        expect(plugin.childrenSignal.value[handle], isA<ChildFailed>());
        expect(plugin.aliveCountSignal.value, 0);
      });

      test('ChildFailed carries the error message', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _failingMock('something broke'),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle =
            (await spawn!({'code': 'raise ValueError("something broke")'}))!
                as int;
        await await_!({'handle': handle}).catchError((_) => null);

        final state = plugin.childrenSignal.value[handle]! as ChildFailed;
        expect(state.message, contains('something broke'));
      });

      test('childrenSignal is empty after sandbox_free', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');

        final handle = (await spawn!({'code': '1'}))! as int;
        await await_!({'handle': handle});
        await free({'handle': handle});

        expect(plugin.childrenSignal.value, isEmpty);
      });

      test('effect() fires when child completes', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final observed = <Map<int, ChildState>>[];
        final dispose = effect(
          () => observed.add(Map.from(plugin.childrenSignal.value)),
        );
        addTearDown(dispose);

        final handle = (await spawn!({'code': '1'}))! as int;
        await await_!({'handle': handle});

        // At least: initial empty, spawned (Running), completed
        expect(observed.length, greaterThanOrEqualTo(2));
        expect(observed.last[handle], isA<ChildCompleted>());
      });

      test('childrenSignal is cleared when dispose runs', () async {
        final plugin = await _attachedPlugin(
          SandboxPlugin(
            platformFactory: () async => _completingMock(),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        await spawn!({'code': '1'});

        // Observe the signal up to the moment dispose fires; the mixin
        // disposes stateSignal in super.onDispose(), so reading after dispose
        // would hit a disposed signal.
        final observed = <Map<int, ChildState>>[];
        final sub = effect(() {
          observed.add(Map.from(plugin.childrenSignal.value));
        });
        await plugin.onDispose();
        sub();

        expect(observed.last, isEmpty);
      });
    });
  });
}

/// Finds a handler by function name and wraps it with [_testCtx].
Future<Object?> Function(Map<String, Object?>) _findHandler(
  SandboxPlugin plugin,
  String name,
) {
  final h = plugin.functions.firstWhere((f) => f.schema.name == name).handler!;
  return (args) => h(args, _testCtx);
}

/// A [MontyPlatform] whose [start] hangs until a [Completer] is completed.
///
/// This keeps the child bridge "running" so tests can observe alive state,
/// alive state and concurrency limits before the child finishes.
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
