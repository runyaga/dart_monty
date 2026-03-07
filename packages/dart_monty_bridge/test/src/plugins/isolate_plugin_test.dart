import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/dart_monty_testing.dart';
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
  return MockMontyPlatform()
    ..enqueueProgress(
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
  return MockMontyPlatform()
    ..enqueueProgress(
      MontyComplete(
        result: MontyResult(
          error: MontyException(message: message),
          usage: _usage,
        ),
      ),
    );
}

void main() {
  group('IsolatePlugin', () {
    group('metadata', () {
      test('namespace is "isolate"', () {
        final plugin = IsolatePlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.namespace, 'isolate');
      });

      test('has system prompt context', () {
        final plugin = IsolatePlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.systemPromptContext, isNotNull);
        expect(plugin.systemPromptContext, contains('isolated'));
      });

      test('provides 7 host functions', () {
        final plugin = IsolatePlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        expect(plugin.functions, hasLength(7));
      });

      test('all function names start with isolate_', () {
        final plugin = IsolatePlugin(
          platformFactory: () async => MockMontyPlatform(),
        );
        for (final fn in plugin.functions) {
          expect(fn.schema.name, startsWith('isolate_'));
        }
      });

      test('registers on PluginRegistry without collision', () {
        final registry = PluginRegistry()
          ..register(
            IsolatePlugin(platformFactory: () async => MockMontyPlatform()),
          );
        expect(registry.plugins, hasLength(1));
      });
    });

    group('isolate_spawn', () {
      test('returns an integer handle', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

        final handle = await spawn({'code': 'x = 1'});

        expect(handle, isA<int>());
        expect(handle, 0);
      });

      test('sequential spawns return incrementing handles', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

        final h0 = await spawn({'code': 'a'});
        final h1 = await spawn({'code': 'b'});
        final h2 = await spawn({'code': 'c'});

        expect(h0, 0);
        expect(h1, 1);
        expect(h2, 2);
      });

      test('passes code to child platform start()', () async {
        final mock = _completingMock();
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');

        await spawn({'code': 'print("hello")'});

        // The bridge wraps code with print preamble, so check the mock
        // received something containing our code.
        expect(mock.lastStartCode, contains('print("hello")'));
      });

      test('child platform is disposed after completion', () async {
        final mock = _completingMock();
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': '42'});

        await await_({'handle': handle! as int});

        expect(mock.isDisposed, isTrue);
      });

      test('applies timeout_ms and memory_bytes to child limits', () async {
        final mock = _completingMock();
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');

        await spawn({'code': '1', 'timeout_ms': 5000, 'memory_bytes': 1048576});

        // Give the bridge time to call start().
        await Future<void>.delayed(Duration.zero);

        expect(mock.lastStartLimits, isNotNull);
        expect(mock.lastStartLimits!.timeoutMs, 5000);
        expect(mock.lastStartLimits!.memoryBytes, 1048576);
      });

      test('throws StateError when disposed', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        await plugin.onDispose();
        final spawn = _findHandler(plugin, 'isolate_spawn');

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

    group('isolate_await', () {
      test('returns null for child with no return value', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': 'x = 1'});
        final result = await await_({'handle': handle! as int});

        expect(result, isNull);
      });

      test('returns child return value', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMockWithResult(value: 42),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': '42'});
        final result = await await_({'handle': handle! as int});

        expect(result, 42);
      });

      test('throws for failed child', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _failingMock('NameError: x'),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': 'x'});

        expect(
          () => await_({'handle': handle! as int}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('NameError'),
            ),
          ),
        );
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final await_ = _findHandler(plugin, 'isolate_await');

        expect(() => await_({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('isolate_await_all', () {
      test('returns results for all children', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final awaitAll = _findHandler(plugin, 'isolate_await_all');
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
        final plugin = IsolatePlugin(
          platformFactory: () async {
            callCount++;
            if (callCount == 2) return _failingMock('boom');
            return _completingMock();
          },
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final awaitAll = _findHandler(plugin, 'isolate_await_all');
        final h0 = await spawn({'code': 'ok'});
        final h1 = await spawn({'code': 'fail'});

        expect(
          () => awaitAll({
            'handles': <Object?>[h0, h1],
          }),
          throwsA(isA<StateError>()),
        );
      });

      test('throws ArgumentError for unknown handle in list', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final awaitAll = _findHandler(plugin, 'isolate_await_all');

        expect(
          () => awaitAll({
            'handles': <Object?>[42],
          }),
          throwsA(isA<ArgumentError>()),
        );
      });
    });

    group('isolate_is_alive', () {
      test('returns true while child is running', () async {
        // Use a slow platform that doesn't resolve start() immediately.
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);

        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final isAlive = _findHandler(plugin, 'isolate_is_alive');
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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final isAlive = _findHandler(plugin, 'isolate_is_alive');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        final alive = await isAlive({'handle': handle as int});
        expect(alive, isFalse);
      });

      test('throws ArgumentError for unknown handle', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final isAlive = _findHandler(plugin, 'isolate_is_alive');

        expect(() => isAlive({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('isolate_cancel', () {
      test('cancels a running child', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final cancel = _findHandler(plugin, 'isolate_cancel');
        final isAlive = _findHandler(plugin, 'isolate_is_alive');
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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final cancel = _findHandler(plugin, 'isolate_cancel');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        final result = await cancel({'handle': handle as int});
        expect(result, isNull);
      });

      test('await on cancelled child throws', () async {
        final startCompleter = Completer<MontyProgress>();
        final plugin = IsolatePlugin(
          platformFactory: () async => _SlowMockPlatform(startCompleter.future),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final cancel = _findHandler(plugin, 'isolate_cancel');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': 'wait_forever()'});

        await cancel({'handle': handle! as int});

        expect(
          () => await_({'handle': handle as int}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('cancelled'),
            ),
          ),
        );

        // Unblock the suspended bridge so _run() can finish cleanly.
        startCompleter.complete(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );
      });
    });

    group('isolate_get_output', () {
      test('returns print output from completed child', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async =>
              _completingMockWithResult(printOutput: 'hello world\n'),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final getOutput = _findHandler(plugin, 'isolate_get_output');
        final handle = await spawn({'code': 'print("hello world")'});

        await await_({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, 'hello world\n');
      });

      test('returns null when child had no print output', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final getOutput = _findHandler(plugin, 'isolate_get_output');
        final handle = await spawn({'code': '42'});

        await await_({'handle': handle! as int});

        final output = await getOutput({'handle': handle as int});
        expect(output, isNull);
      });

      test('throws StateError when child is still running', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final getOutput = _findHandler(plugin, 'isolate_get_output');
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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final getOutput = _findHandler(plugin, 'isolate_get_output');

        expect(() => getOutput({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('isolate_free', () {
      test('removes completed child from map', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final free = _findHandler(plugin, 'isolate_free');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        // Handle is now unknown.
        final getOutput = _findHandler(plugin, 'isolate_get_output');
        expect(
          () => getOutput({'handle': handle}),
          throwsA(isA<ArgumentError>()),
        );
      });

      test('throws StateError when child is still running', () async {
        final startCompleter = Completer<MontyProgress>();
        final mock = _SlowMockPlatform(startCompleter.future);
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final free = _findHandler(plugin, 'isolate_free');
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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final free = _findHandler(plugin, 'isolate_free');

        expect(() => free({'handle': 999}), throwsA(isA<ArgumentError>()));
      });

      test('double free throws ArgumentError', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final free = _findHandler(plugin, 'isolate_free');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        expect(
          () => free({'handle': handle}),
          throwsA(isA<ArgumentError>()),
        );
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
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final getOutput = _findHandler(plugin, 'isolate_get_output');
        final handle = await spawn({'code': 'print("debug line"); x'});

        // Await will throw because the child failed.
        await expectLater(
          () => await_({'handle': handle! as int}),
          throwsA(isA<StateError>()),
        );

        final output = await getOutput({'handle': handle! as int});
        expect(output, contains('debug'));
      });
    });

    group('depth limiting', () {
      test('rejects spawn when currentDepth >= maxDepth', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
          maxDepth: 2,
          currentDepth: 2,
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
          currentDepth: 1,
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

        final handle = await spawn({'code': '1'});
        expect(handle, isA<int>());
      });
    });

    group('concurrency limiting', () {
      test('rejects spawn when maxChildren reached', () async {
        final completers = <Completer<MontyProgress>>[];
        final plugin = IsolatePlugin(
          platformFactory: () async {
            final c = Completer<MontyProgress>();
            completers.add(c);
            return _SlowMockPlatform(c.future);
          },
          maxChildren: 2,
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

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

    group('onDispose', () {
      test('cancels all living children', () async {
        final completers = <Completer<MontyProgress>>[];
        final mocks = <_SlowMockPlatform>[];
        final plugin = IsolatePlugin(
          platformFactory: () async {
            final c = Completer<MontyProgress>();
            completers.add(c);
            final m = _SlowMockPlatform(c.future);
            mocks.add(m);
            return m;
          },
        );
        final spawn = _findHandler(plugin, 'isolate_spawn');

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
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
        );

        await plugin.onDispose();
        await plugin.onDispose();
      });

      test('completed children are not cancelled again', () async {
        final mock = _completingMock();
        final plugin = IsolatePlugin(platformFactory: () async => mock);
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});

        await plugin.onDispose();

        expect(mock.isDisposed, isTrue);
      });
    });

    group('child plugin wiring', () {
      test('child gets plugins from factory', () async {
        final plugin = IsolatePlugin(
          platformFactory: () async => _completingMock(),
          childPluginRegistryFactory: () async {
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
        final spawn = _findHandler(plugin, 'isolate_spawn');
        final await_ = _findHandler(plugin, 'isolate_await');
        final handle = await spawn({'code': 'helper_ping()'});

        await await_({'handle': handle! as int});
      });
    });
  });
}

/// Finds a handler by function name from the plugin's function list.
HostFunctionHandler _findHandler(IsolatePlugin plugin, String name) {
  return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
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
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) =>
      _startFuture;

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
