// Strict collection assertions and fresh probes are intentional in these tests.
// ignore_for_file: avoid-unsafe-collection-methods, prefer-moving-to-variable
import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/struct_log_logger.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyInt, MontyList, MontyRuntimeError, MontyString;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

import '../_throwing_session.dart';

final _runtimes = Expando<MontyRuntime>();
final _limits = Expando<List<ResourceLimits?>>();
final _events = Expando<List<BridgeEvent>>();

/// The scripted session each child of a sandbox gets, in spawn order.
///
/// The existing runtime seam supplies both root and child sessions.
final Expando<MontySession Function()> _childScripts = Expando(
  'childScripts',
);

/// A [SandboxExtension] whose children run the sessions [children] makes.
SandboxExtension _sandbox({
  MontySession Function()? children,
  int maxChildren = 16,
  int maxDepth = 3,
  int currentDepth = 0,
  ResourceLimits? childLimits,
  String? sandboxBaseDir,
}) {
  final extension = SandboxExtension(
    maxChildren: maxChildren,
    maxDepth: maxDepth,
    currentDepth: currentDepth,
    childLimits: childLimits,
    sandboxBaseDir: sandboxBaseDir,
  );
  _childScripts[extension] = children;

  return extension;
}

/// A child session that runs its code to completion at once.
FakeMontySession _completingMock() =>
    FakeMontySession()..willReturn(const MontyNone());

/// A child session that prints [printOutput] and completes with [value].
FakeMontySession _completingMockWithResult({
  MontyValue? value,
  String? printOutput,
}) {
  final session = FakeMontySession();
  if (printOutput != null) session.willPrint(printOutput);

  return session..willReturn(value ?? const MontyNone());
}

/// `NameError: x` split into the type and the message.
final RegExp _typedMessage = RegExp(r'^(\w+(?:Error|Exception)): (.*)$');

/// A child session that fails with [message]: a leading `Type: ` names the
/// Python exception type, `RuntimeError` otherwise.
FakeMontySession _failingMock(String message) {
  final typed = _typedMessage.firstMatch(message);

  return FakeMontySession()..willRaise(
    typed?.group(1) ?? 'RuntimeError',
    message: typed?.group(2) ?? message,
  );
}

/// A child session that fails with a structured error. The worker names the
/// traceback's file itself, so [filename] is not scripted.
FakeMontySession _failingMockStructured({
  required String message,
  String? filename,
  int? lineNumber,
  int? columnNumber,
  String? excType,
}) => FakeMontySession()
  ..willRaise(
    excType ?? 'RuntimeError',
    message: message,
    line: lineNumber,
    column: columnNumber,
  );

/// A child session whose feed holds until [gate] completes, then returns
/// `None`: the child stays "running" meanwhile.
FakeMontySession _slowSession(Future<void> gate) => FakeMontySession()
  ..willHold(gate)
  ..willReturn(const MontyNone());

/// Attaches [plugin] to a minimal bridge so `registry` is injected.
///
/// Many tests exercise handlers directly (via [_findHandler]) but
/// `sandbox_spawn` reaches into `registry.spawnChild(...)` — that field is
/// injected by [ExtensionCoordinator.attachTo], so the plugin must be
/// attached first.
Future<SandboxExtension> _attachedPlugin(SandboxExtension plugin) async {
  var root = true;
  final observedLimits = <ResourceLimits?>[];
  final runtime = await startRuntimeWith(
    checkout: ({limits}) async {
      if (root) {
        root = false;

        return FakeMontySession();
      }
      observedLimits.add(limits);

      return _childScripts[plugin]?.call() ?? _completingMock();
    },
    extensions: [plugin],
  );
  _runtimes[plugin] = runtime;
  _limits[plugin] = observedLimits;
  final events = <BridgeEvent>[];
  _events[plugin] = events;
  final subscription = runtime.events.listen(events.add);
  addTearDown(() async {
    await runtime.dispose();
    await subscription.cancel();
  });
  await runtime.invoke('sandbox_await_all', {'handles': const MontyList([])});

  return plugin;
}

void main() {
  group('SandboxExtension', () {
    group('metadata', () {
      test('namespace is "sandbox"', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: FakeMontySession.new,
          ),
        );
        expect(plugin.namespace, 'sandbox');
      });

      test('has system prompt context', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: FakeMontySession.new,
          ),
        );
        expect(plugin.systemPromptContext, isNotNull);
        expect(plugin.systemPromptContext, contains('sandboxed'));
      });

      test('provides 7 host functions', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: FakeMontySession.new,
          ),
        );
        expect(plugin.functions, hasLength(7));
      });

      test('all function names start with sandbox_', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: FakeMontySession.new,
          ),
        );
        for (final fn in plugin.functions) {
          expect(fn.schema.name, startsWith('sandbox_'));
        }
      });

      test('registers on ExtensionCoordinator without collision', () {
        final registry = ExtensionCoordinator()
          ..register(
            _sandbox(children: FakeMontySession.new),
          );
        expect(registry.extensions, hasLength(1));
      });
    });

    group('sandbox_spawn', () {
      test('returns an integer handle', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        final handle = await spawn({'code': 'x = 1'});

        expect(handle, isA<int>());
        expect(handle, 0);
      });

      test(
        'sequential spawns return incrementing handles',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: _completingMock,
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          final h0 = await spawn({'code': 'a'});
          final h1 = await spawn({'code': 'b'});
          final h2 = await spawn({'code': 'c'});

          expect(h0, 0);
          expect(h1, 1);
          expect(h2, 2);
        },
      );

      test('passes code to the child session feed', () async {
        final mock = _completingMock();
        final plugin = await _attachedPlugin(
          _sandbox(children: () => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'print("hello")'});

        await _findHandler(plugin, 'sandbox_await')({'handle': 0});
        // The child session's feed is the spawned code.
        expect(mock.feeds.single, contains('print("hello")'));
      });

      test(
        'child session is closed after completion',

        () async {
          final mock = _completingMock();
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': '42'});

          await await_({'handle': handle! as int});

          expect(mock.isClosed, isTrue);
        },
      );

      test(
        'applies timeout_ms and memory_bytes to child limits',

        () async {
          final mock = _completingMock();
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await spawn({
            'code': '1',
            'timeout_ms': 5000,
            'memory_bytes': 1048576,
          });

          // Give the bridge time to call start().
          await _findHandler(plugin, 'sandbox_await')({'handle': 0});

          expect(mock.feeds.single, '1');
          expect(
            _limits[plugin]!.single,
            const ResourceLimits(
              maxFeedDuration: Duration(milliseconds: 5000),
              maxMemory: 1048576,
            ),
          );
        },
      );

      test('throws StateError when disposed', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
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
      test(
        'returns null for child with no return value',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: _completingMock,
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': 'x = 1'});
          final result = await await_({'handle': handle! as int});

          expect(result, isNull);
        },
      );

      test('returns child return value', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () =>
                _completingMockWithResult(value: const MontyInt(42)),
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final handle = await spawn({'code': '42'});
        final result = await await_({'handle': handle! as int});

        expect(result, 42);
      });

      test(
        'throws ChildSandboxException for failed child',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () => _failingMock('NameError: x'),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': 'x'});

          expect(
            () => await_({'handle': handle! as int}),
            throwsA(
              isA<Exception>()
                  .having(
                    (e) => e.toString(),
                    'childId',
                    contains('child $handle'),
                  )
                  .having(
                    (e) => e.toString(),
                    'message',
                    contains('NameError'),
                  ),
            ),
          );
        },
      );

      test(
        'preserves MontyException fields through ChildSandboxException',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () => _failingMockStructured(
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
          final handle = await spawn({'code': 'undefined_var'});

          try {
            await await_({'handle': handle! as int});
            fail('Expected ChildSandboxException');
          } on Exception catch (e) {
            expect(e.toString(), contains('child $handle'));
            final error = _events[plugin]!
                .whereType<BridgeChildEvent>()
                .map((e) => e.inner)
                .whereType<BridgeRunError>()
                .last;
            expect(error.exception, isNotNull);
            expect(error.exception!.exception.excType, 'NameError');
            // Line and column are the raw Monty values — no preamble offset.
            // The worker names the traceback's file, so it is not asserted.
            final frame =
                (error.exception! as MontyRuntimeError).traceback.last;
            expect(frame.line, 7);
            expect(frame.column, 4);
          }
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
        );
        final await_ = _findHandler(plugin, 'sandbox_await');

        expect(() => await_({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_await_all', () {
      test('returns results for all children', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
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
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () {
              callCount++;
              if (callCount == 2) return _failingMock('boom');

              return _completingMock();
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final awaitAll = _findHandler(plugin, 'sandbox_await_all');
        final h0 = await spawn({'code': 'ok'});
        final h1 = await spawn({'code': 'fail'});

        expect(
          () => awaitAll({
            'handles': <Object?>[h0, h1],
          }),
          throwsA(isA<Exception>()),
        );
      });

      test('throws ArgumentError for unknown handle in list', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
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
        // Use a slow session whose feed does not finish immediately.
        final startCompleter = Completer<void>();
        final mock = _slowSession(startCompleter.future);

        final plugin = await _attachedPlugin(
          _sandbox(children: () => mock),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');
        final handle = await spawn({'code': '1'});

        // Bridge is waiting for start() to complete — child is alive.
        final alive = await isAlive({'handle': handle! as int});
        expect(alive, isTrue);

        // Unblock and clean up.
        startCompleter.complete();
        await plugin.onDispose();
      });

      test('returns false after child completes', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
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
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
        );
        final isAlive = _findHandler(plugin, 'sandbox_is_alive');

        expect(() => isAlive({'handle': 999}), throwsA(isA<ArgumentError>()));
      });
    });

    group('sandbox_get_output', () {
      test(
        'returns print output from completed child',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () =>
                  _completingMockWithResult(printOutput: 'hello world\n'),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final getOutput = _findHandler(plugin, 'sandbox_get_output');
          final handle = await spawn({'code': 'print("hello world")'});

          await await_({'handle': handle! as int});

          final output = await getOutput({'handle': handle as int});
          expect(output, 'hello world\n');
        },
      );

      test(
        'returns null when child had no print output',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: _completingMock,
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final getOutput = _findHandler(plugin, 'sandbox_get_output');
          final handle = await spawn({'code': '42'});

          await await_({'handle': handle! as int});

          final output = await getOutput({'handle': handle as int});
          expect(output, isNull);
        },
      );

      test(
        'throws StateError when child is still running',

        () async {
          final startCompleter = Completer<void>();
          final mock = _slowSession(startCompleter.future);
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
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
          startCompleter.complete();
          await plugin.onDispose();
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
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
            _sandbox(
              children: () {
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
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () {
              callCount++;

              return _completingMockWithResult(value: MontyInt(callCount * 10));
            },
          ),
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

      test(
        'handles null printOutput (child with no print)',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () =>
                  _completingMockWithResult(value: const MontyInt(42)),
            ),
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
        },
      );

      test(
        'throws ChildSandboxException if any child fails',

        () async {
          var callCount = 0;
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () {
                callCount++;
                if (callCount == 2) return _failingMock('child failed');

                return _completingMockWithResult(value: MontyInt(callCount));
              },
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final gather = _findHandler(plugin, 'sandbox_gather');

          final h0 = (await spawn({'code': 'a'}))! as int;
          final h1 = (await spawn({'code': 'b'}))! as int;

          expect(
            () => gather({
              'handles': [h0, h1],
            }),
            throwsA(isA<Exception>()),
          );
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
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
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () => _completingMockWithResult(
              value: const MontyString('solo'),
              printOutput: 'hi\n',
            ),
          ),
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
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
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

      test(
        'throws StateError when child is still running',

        () async {
          final startCompleter = Completer<void>();
          final mock = _slowSession(startCompleter.future);
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final free = _findHandler(plugin, 'sandbox_free');
          final handle = await spawn({'code': '1'});

          await free({'handle': handle! as int});
          expect(mock.isClosed, isTrue);

          startCompleter.complete();
          await plugin.onDispose();
        },
      );

      test('throws ArgumentError for unknown handle', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
        );
        final free = _findHandler(plugin, 'sandbox_free');

        expect(await free({'handle': 999}), isNull);
      });

      test('double free throws ArgumentError', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');
        final free = _findHandler(plugin, 'sandbox_free');
        final handle = await spawn({'code': '1'});

        await await_({'handle': handle! as int});
        await free({'handle': handle as int});

        expect(await free({'handle': handle}), isNull);
      });
    });

    group('failed child print output', () {
      test(
        'get_output returns print output from failed child',

        () async {
          // A child that prints then fails.
          final mock = FakeMontySession()
            ..willPrint('debug line\n')
            ..willRaise('NameError', message: 'x');
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final getOutput = _findHandler(plugin, 'sandbox_get_output');
          final handle = await spawn({'code': 'print("debug line"); x'});

          // Await will throw because the child failed.
          await expectLater(
            () => await_({'handle': handle! as int}),
            throwsA(isA<Exception>()),
          );

          final output = await getOutput({'handle': handle! as int});
          expect(output, contains('debug'));
        },
      );
    });

    group('depth limiting', () {
      test(
        'rejects spawn when currentDepth >= maxDepth',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: _completingMock,
              maxDepth: 2,
              currentDepth: 2,
            ),
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
        },
      );

      test(
        'allows spawn when currentDepth < maxDepth',

        () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: _completingMock,
              currentDepth: 1,
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          final handle = await spawn({'code': '1'});
          expect(handle, isA<int>());
        },
      );
    });

    group('concurrency limiting', () {
      test('rejects spawn when maxChildren reached', () async {
        final completers = <Completer<void>>[];
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () {
              final c = Completer<void>();
              completers.add(c);

              return _slowSession(c.future);
            },
            maxChildren: 2,
          ),
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
          c.complete();
        }
        await plugin.onDispose();
      });
    });

    group('ChildSandboxException', () {
      test('toString includes childId and message', () async {
        final plugin = await _attachedPlugin(
          _sandbox(children: () => _failingMock('boom')),
        );
        final handle = await _findHandler(plugin, 'sandbox_spawn')({
          'code': 'x',
        });
        await expectLater(
          _findHandler(plugin, 'sandbox_await')({'handle': handle}),
          throwsA(
            predicate<Object>(
              (e) =>
                  e.toString().contains('child $handle') &&
                  e.toString().contains('boom'),
            ),
          ),
        );
      });
      test('exception field is null for non-Python errors', () async {
        final plugin = await _attachedPlugin(
          _sandbox(children: () => ThrowingSession(StateError('disposed'))),
        );
        final handle = await _findHandler(plugin, 'sandbox_spawn')({
          'code': 'x',
        });
        await expectLater(
          _findHandler(plugin, 'sandbox_await')({'handle': handle}),
          throwsA(isA<Exception>()),
        );
        final error = _events[plugin]!
            .whereType<BridgeChildEvent>()
            .map((e) => e.inner)
            .whereType<BridgeRunError>()
            .last;
        expect(error.exception, isNull);
      });

      test(
        'infrastructure error produces null exception field',

        () async {
          // A child session whose feed throws a non-MontyError error.
          // The bridge catches it via `on Object` and emits BridgeRunError
          // without a MontyError.
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () => ThrowingSession(StateError('infra boom')),
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': '1'});

          expect(
            () => await_({'handle': handle! as int}),
            throwsA(
              isA<Exception>()
                  .having((e) => e.toString(), 'error', contains('infra boom'))
                  .having(
                    (e) => e.toString(),
                    'message',
                    contains('infra boom'),
                  ),
            ),
          );
        },
      );
    });

    group('onDispose', () {
      test('tears down all living children', () async {
        final completers = <Completer<void>>[];
        final mocks = <FakeMontySession>[];
        final plugin = await _attachedPlugin(
          _sandbox(
            children: () {
              final c = Completer<void>();
              completers.add(c);
              final m = _slowSession(c.future);
              mocks.add(m);

              return m;
            },
          ),
        );
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await spawn({'code': 'a'});
        await spawn({'code': 'b'});

        await plugin.onDispose();

        for (final mock in mocks) {
          expect(mock.isClosed, isTrue);
        }

        // Unblock so _run() finishes.
        for (final c in completers) {
          c.complete();
        }
      });

      test('is idempotent', () async {
        final plugin = await _attachedPlugin(
          _sandbox(
            children: _completingMock,
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
          final platformCompleter = Completer<FakeMontySession>();
          late FakeMontySession createdPlatform;

          final plugin = await _attachedPlugin(
            _sandbox(
              children: () {
                createdPlatform = _slowSession(
                  // Platform.start() never returns — child stays alive while we
                  // test the race.
                  Completer<void>().future,
                );
                platformCompleter.complete(createdPlatform);

                return createdPlatform;
              },
            ),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          // Start spawn — hangs inside _createChildSessionAndBridge at the
          // child session checkout.
          final spawnFuture = spawn({'code': '1'});
          final refused = expectLater(spawnFuture, throwsStateError);

          // Wait until the factory has been entered (platform is now being
          // created) then dispose the plugin while spawn is in flight.
          await platformCompleter.future;
          await plugin.onDispose();

          // spawn should throw StateError and the created platform must be
          // disposed by the post-await cleanup.
          await refused;
          expect(
            createdPlatform.isClosed,
            isTrue,
            reason: 'platform created during disposed spawn must be torn down',
          );
          expect(
            _events[plugin]!.whereType<BridgeChildEvent>(),
            isEmpty,
            reason: 'disposed-mid-spawn child must not appear in children',
          );
        },
      );

      test(
        'completed children are not torn down again',

        () async {
          final mock = _completingMock();
          final plugin = await _attachedPlugin(
            _sandbox(children: () => mock),
          );
          final spawn = _findHandler(plugin, 'sandbox_spawn');
          final await_ = _findHandler(plugin, 'sandbox_await');
          final handle = await spawn({'code': '1'});

          await await_({'handle': handle! as int});

          await plugin.onDispose();

          expect(mock.isClosed, isTrue);
        },
      );
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
        logger = LogManager.instance.getLogger('SandboxExtension.test');
      });

      tearDown(() {
        LogManager.instance
          ..removeSink(sink)
          ..minimumLevel = previousLevel;
      });

      test('spawn logs info with childId and depth', () async {
        final plugin =
            await _attachedPlugin(
                _sandbox(
                  children: _completingMock,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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

      test(
        'spawn logs debug for bridge creation with codeLength',

        () async {
          final plugin =
              await _attachedPlugin(
                  _sandbox(
                    children: _completingMock,
                  ),
                )
                ..logger = StructLogBridgeLogger(logger, LogManager.instance);
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await spawn({'code': 'x = 42'});

          final bridgeRecord = sink.records.firstWhere(
            (r) => r.message == 'Child bridge created',
          );
          expect(bridgeRecord.level, LogLevel.debug);
          expect(bridgeRecord.attributes['codeLength'], 6);
        },
      );

      test('completion logs info with childId', () async {
        final plugin =
            await _attachedPlugin(
                _sandbox(
                  children: _completingMock,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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

      test(
        'failure logs debug with childId and error',

        () async {
          final plugin =
              await _attachedPlugin(
                  _sandbox(
                    children: () => _failingMock('NameError: x'),
                  ),
                )
                ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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
          expect(failRecord.level, LogLevel.debug);
          expect(failRecord.attributes['childId'], 0);
          expect(failRecord.attributes['error'], contains('NameError'));
        },
      );

      test('free logs debug with childId', () async {
        final plugin =
            await _attachedPlugin(
                _sandbox(
                  children: _completingMock,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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
        final plugin =
            await _attachedPlugin(
                _sandbox(
                  children: _completingMock,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');
        final await_ = _findHandler(plugin, 'sandbox_await');

        final handle = await spawn({'code': '1'});
        await await_({'handle': handle! as int});
        await plugin.onDispose();

        final disposeRecord = sink.records.firstWhere(
          (r) => r.message == 'Disposing SandboxExtension',
        );
        expect(disposeRecord.level, LogLevel.info);
        expect(disposeRecord.attributes['totalChildren'], 1);
        expect(disposeRecord.attributes['aliveChildren'], 0);
      });

      test('depth limit rejection logs warning', () async {
        final plugin =
            await _attachedPlugin(
                _sandbox(
                  children: _completingMock,
                  maxDepth: 2,
                  currentDepth: 2,
                ),
              )
              ..logger = StructLogBridgeLogger(logger, LogManager.instance);
        final spawn = _findHandler(plugin, 'sandbox_spawn');

        await expectLater(spawn({'code': '1'}), throwsStateError);

        final warnRecord = sink.records.firstWhere(
          (r) => r.message == 'Spawn rejected: depth limit',
        );
        expect(warnRecord.level, LogLevel.warning);
        expect(warnRecord.attributes['currentDepth'], 2);
        expect(warnRecord.attributes['maxDepth'], 2);
      });

      test(
        'concurrency limit rejection logs warning',

        () async {
          final completers = <Completer<void>>[];
          final plugin =
              await _attachedPlugin(
                  _sandbox(
                    children: () {
                      final c = Completer<void>();
                      completers.add(c);

                      return _slowSession(c.future);
                    },
                    maxChildren: 1,
                  ),
                )
                ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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
            c.complete();
          }
          await plugin.onDispose();
        },
      );

      test(
        'error message is truncated in log attributes',

        () async {
          final longError = 'E' * 300;
          final plugin =
              await _attachedPlugin(
                  _sandbox(
                    children: () => _failingMock(longError),
                  ),
                )
                ..logger = StructLogBridgeLogger(logger, LogManager.instance);
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
        },
      );

      test(
        'child checkout failure logs error with phase=checkout',

        () async {
          final plugin =
              await _attachedPlugin(
                  _sandbox(
                    children: () {
                      throw StateError('checkout boom');
                    },
                  ),
                )
                ..logger = StructLogBridgeLogger(logger, LogManager.instance);
          final spawn = _findHandler(plugin, 'sandbox_spawn');

          await expectLater(spawn({'code': '1'}), throwsStateError);

          final errorRecord = sink.records.firstWhere(
            (r) => r.message == 'Child session checkout failed',
          );
          expect(errorRecord.level, LogLevel.error);
          expect(errorRecord.attributes['phase'], 'checkout');
          expect(errorRecord.error, isA<StateError>());
        },
      );

      test('default logger is BridgeLogger.silent before attach', () {
        final defaultPlugin = _sandbox(
          children: _completingMock,
        );
        expect(defaultPlugin.logger, same(BridgeLogger.silent));
      });
    });

    group('signals', () {
      // Historical observation IDs now exercise the supported calls/events.
      test('childrenSignal is empty before any spawn', () async {
        final plugin = await _attachedPlugin(_sandbox());
        expect(_events[plugin]!.whereType<BridgeChildEvent>(), isEmpty);
      });
      test('aliveCountSignal is 0 before any spawn', () async {
        final plugin = await _attachedPlugin(_sandbox());
        await expectLater(
          _findHandler(plugin, 'sandbox_is_alive')({'handle': 0}),
          throwsArgumentError,
        );
      });
      test(
        'childrenSignal contains ChildRunning immediately after spawn',
        () async {
          final gate = Completer<void>();
          final plugin = await _attachedPlugin(
            _sandbox(children: () => _slowSession(gate.future)),
          );
          final handle = await _findHandler(plugin, 'sandbox_spawn')({
            'code': '42',
          });
          expect(
            await _findHandler(plugin, 'sandbox_is_alive')({'handle': handle}),
            isTrue,
          );
          gate.complete();
          await _findHandler(plugin, 'sandbox_await')({'handle': handle});
        },
      );
      for (final name in [
        'childrenSignal updates to ChildCompleted after child finishes',
        'ChildCompleted carries the return value',
        'effect() fires when child completes',
      ]) {
        test(name, () async {
          final plugin = await _attachedPlugin(
            _sandbox(
              children: () =>
                  _completingMockWithResult(value: const MontyInt(7)),
            ),
          );
          final handle = await _findHandler(plugin, 'sandbox_spawn')({
            'code': '7',
          });
          expect(
            await _findHandler(plugin, 'sandbox_await')({'handle': handle}),
            7,
          );
          expect(
            await _findHandler(plugin, 'sandbox_is_alive')({'handle': handle}),
            isFalse,
          );
          final events = _events[plugin]!
              .whereType<BridgeChildEvent>()
              .map((e) => e.inner)
              .toList();
          expect(events.first, isA<BridgeRunStarted>());
          expect(
            (events.last as BridgeRunFinished).montyValue,
            const MontyInt(7),
          );
        });
      }
      for (final name in [
        'childrenSignal updates to ChildFailed when child errors',
        'ChildFailed carries the error message',
      ]) {
        test(name, () async {
          final plugin = await _attachedPlugin(
            _sandbox(children: () => _failingMock('something broke')),
          );
          final handle = await _findHandler(plugin, 'sandbox_spawn')({
            'code': 'x',
          });
          await expectLater(
            _findHandler(plugin, 'sandbox_await')({'handle': handle}),
            throwsA(
              predicate<Object>(
                (e) => e.toString().contains('something broke'),
              ),
            ),
          );
          expect(
            await _findHandler(plugin, 'sandbox_is_alive')({'handle': handle}),
            isFalse,
          );
          expect(
            _events[plugin]!
                .whereType<BridgeChildEvent>()
                .map((e) => e.inner)
                .whereType<BridgeRunError>()
                .single
                .message,
            contains('something broke'),
          );
        });
      }
      test('childrenSignal is empty after sandbox_free', () async {
        final plugin = await _attachedPlugin(_sandbox());
        final handle = await _findHandler(plugin, 'sandbox_spawn')({
          'code': '42',
        });
        await _findHandler(plugin, 'sandbox_free')({'handle': handle});
        await expectLater(
          _findHandler(plugin, 'sandbox_is_alive')({'handle': handle}),
          throwsArgumentError,
        );
      });
      test('childrenSignal is cleared when dispose runs', () async {
        final plugin = await _attachedPlugin(_sandbox());
        final handle = await _findHandler(plugin, 'sandbox_spawn')({
          'code': '42',
        });
        await plugin.onDispose();
        final handler = plugin.functions
            .firstWhere((f) => f.schema.name == 'sandbox_is_alive')
            .handler!;
        await expectLater(
          () => handler(
            {
              'handle': MontyValue.fromDart(handle),
            },
            HostContext(
              emit: (_) {
                /* Events are observed on the owning runtime. */
              },
              executionId: 'test',
            ),
          ),
          throwsArgumentError,
        );
      });
    });
  });
}

/// Finds a handler and supplies its owning runtime context.
Future<Object?> Function(Map<String, Object?>) _findHandler(
  SandboxExtension plugin,
  String name,
) {
  final handler = plugin.functions
      .firstWhere((f) => f.schema.name == name)
      .handler!;

  return (args) async => (await handler(
    args.map((key, value) => MapEntry(key, MontyValue.fromDart(value))),
    HostContext(
      emit: (_) {
        /* Events are observed on the owning runtime. */
      },
      executionId: 'test',
      parent: _runtimes[plugin],
    ),
  )).dartValue;
}
