@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import 'template_stub_extension.dart';

/// Integration tests for MontyRuntime — requires the native Monty
/// library.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/monty_runtime_test.dart
/// ```
void main() {
  group('MontyRuntime stateful execution', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start();
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'simple expression',
      () async {
        final result = await session.execute('2 + 2').result;

        expect(result.dartValue, 4);
      },
      tags: 'd1-pending',
    );

    test(
      'variables persist across execute() calls',
      () async {
        await session.execute('x = 42').result;
        await session.execute('y = x * 2').result;
        final result = await session.execute('x + y').result;

        expect(result.dartValue, 126);
      },
      tags: 'd1-pending',
    );

    test(
      'string variables persist',
      () async {
        await session.execute('name = "monty"').result;
        final result = await session.execute('name.upper()').result;

        expect(result.dartValue, 'MONTY');
      },
      tags: 'd1-pending',
    );

    test(
      'list variables persist',
      () async {
        await session.execute('data = [1, 2, 3]').result;
        await session.execute('data.append(4)').result;
        final result = await session.execute('sum(data)').result;

        expect(result.dartValue, 10);
      },
      tags: 'd1-pending',
    );

    test(
      'dict variables persist',
      () async {
        await session.execute('config = {"debug": True, "level": 5}').result;
        final result = await session.execute('config["debug"]').result;

        expect(result.dartValue, true);
      },
      tags: 'd1-pending',
    );

    test(
      'clearState() resets all variables',
      () async {
        await session.execute('x = 42').result;
        await session.clearState();
        await expectLater(
          session.execute('x').result,
          throwsA(isA<MontyError>()),
        );
      },
      tags: 'd1-pending',
    );

    test(
      'multiple types in state',
      () async {
        await session.execute('a = 1; b = 2.5; c = "hello"; d = True').result;
        final result = await session.execute('[a, b, c, d]').result;

        expect(result.dartValue, [1, 2.5, 'hello', true]);
      },
      tags: 'd1-pending',
    );

    // Regression: augmented assignment previously caused SyntaxError because
    // captureLastExpression wrapped `x += 1` as `__r = (x += 1)` — invalid
    // Python.
    test(
      'augmented assignment (x += 1) does not error',
      () async {
        await session.execute('x = 10').result;
        await session.execute('x += 1').result;

        final val = await session.execute('x').result;
        expect(val.dartValue, 11);
      },
      tags: 'd1-pending',
    );

    // Regression: functions were previously coerced to their string repr by the
    // persist→restore round-trip and became NameError on the second call.
    test(
      'function defined in one call callable in next',
      () async {
        await session.execute('def add(a, b): return a + b').result;
        final result = await session.execute('add(3, 4)').result;

        expect(result.dartValue, 7);
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime with host functions', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start();
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'registered host function callable from Python',
      () async {
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'double_it',
              description: 'Doubles a number',
              params: [HostParam(name: 'n', type: HostParamType.integer)],
            ),
            handler: (args, _) async => (args['n']! as int) * 2,
          ),
        );

        final result = await session.execute('double_it(21)').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'host function result persists in state',
      () async {
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'get_data',
              description: 'Returns sample data',
            ),
            handler: (_, _) async => [1, 2, 3, 4, 5],
          ),
        );

        await session.execute('data = get_data()').result;
        final result = await session.execute('sum(data)').result;

        expect(result.dartValue, 15);
      },
      tags: 'd1-pending',
    );

    test(
      'schemas include registered functions',
      () {
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'my_tool',
              description: 'A custom tool',
            ),
            handler: (_, _) async => null,
          ),
        );

        final names = session.schemas.map((s) => s.name).toList();

        expect(names, contains('my_tool'));
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime with filesystem', () {
    late MontyRuntime session;

    setUp(() async {
      // Use memory filesystem for these tests (not LocalFileSystem)
      session = await MontyRuntime.start(
        osHandlers: {'Path.': memoryFsHandler()},
      );
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'write and read file via pathlib',
      () async {
        await session
            .execute(
              'from pathlib import Path\n'
              'Path("/data/test.txt").write_text("hello from agent")',
            )
            .result;
        final result = await session
            .execute(
              'from pathlib import Path\n'
              'Path("/data/test.txt").read_text()',
            )
            .result;

        expect(result.dartValue, 'hello from agent');
      },
      tags: 'd1-pending',
    );

    test(
      'filesystem state persists across calls',
      () async {
        await session
            .execute(
              'from pathlib import Path\n'
              'Path("/data").mkdir(parents=True, exist_ok=True)\n'
              'Path("/data/counter.txt").write_text("0")',
            )
            .result;

        await session
            .execute(
              'from pathlib import Path\n'
              'n = int(Path("/data/counter.txt").read_text())\n'
              'Path("/data/counter.txt").write_text(str(n + 1))',
            )
            .result;

        final result = await session
            .execute(
              'from pathlib import Path\n'
              'int(Path("/data/counter.txt").read_text())',
            )
            .result;

        expect(result.dartValue, 1);
      },
      tags: 'd1-pending',
    );

    test(
      'date.today() returns reasonable year',
      () async {
        // Note: date objects stored in state are not JSON-serializable,
        // so we extract the year immediately rather than persisting.
        final result = await session
            .execute(
              'from datetime import date\n'
              'date.today().year >= 2024',
            )
            .result;

        expect(result.dartValue, true);
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime error handling', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start();
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'Python error returns error result',
      () async {
        await expectLater(
          session.execute('1 / 0').result,
          throwsA(isA<MontyError>()),
        );
      },
      tags: 'd1-pending',
    );

    test(
      'error does not break state',
      () async {
        await session.execute('x = 42').result;
        // Raises; x must survive it.
        await expectLater(
          session.execute('1 / 0').result,
          throwsA(isA<MontyError>()),
        );
        final result = await session.execute('x').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test('execute after dispose throws', () async {
      await session.dispose();

      expect(
        () => session.execute('1 + 1'),
        throwsStateError,
      );
    });
  });

  group('MontyRuntime sandbox mode', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start(sandbox: true);
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'simple expression',
      () async {
        final result = await session.execute('2 + 2').result;

        expect(result.dartValue, 4);
      },
      tags: 'd1-pending',
    );

    test('isSandboxMode is true', () {
      expect(session.isSandboxMode, isTrue);
    });

    // Sandbox mode runs a fresh session per execute() call — state does
    // NOT persist between calls (no restore/persist serialization).
    test(
      'each execute() is isolated — variables do not carry over',
      () async {
        await session.execute('x = 42').result;
        await expectLater(
          session.execute('x + 1').result,
          throwsA(isA<MontyError>()),
        );
      },
      tags: 'd1-pending',
    );

    test(
      'consecutive calls each run in an independent fresh interpreter',
      () async {
        final r1 = await session.execute('2 + 2').result;
        final r2 = await session.execute('3 + 3').result;

        expect(r1.dartValue, 4);
        expect(r2.dartValue, 6);
      },
      tags: 'd1-pending',
    );

    test(
      'host function callable from sandbox',
      () async {
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'double_it',
              description: 'Doubles a number',
              params: [
                HostParam(
                  name: 'n',
                  type: HostParamType.integer,
                ),
              ],
            ),
            handler: (args, _) async => (args['n']! as int) * 2,
          ),
        );

        final result = await session.execute('double_it(21)').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'host function available within same call',
      () async {
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'greet',
              description: 'Returns greeting',
              params: [HostParam(name: 'name', type: HostParamType.string)],
            ),
            handler: (args, _) async => 'Hello, ${args['name']}!',
          ),
        );

        // Both the call and the result access are in the same execute() call.
        final result = await session.execute('greet("World")').result;

        expect(result.dartValue, 'Hello, World!');
      },
      tags: 'd1-pending',
    );

    test(
      'clearState() is a no-op — sandbox already starts fresh',
      () async {
        await session.execute('x = 99').result;
        await session.clearState(); // no-op in sandbox mode
        // x was never going to be visible in a fresh interpreter anyway
        final result = await session.execute('''
try:
    result = x
except NameError:
    result = "gone"
result
''').result;

        expect(result.dartValue, 'gone');
      },
      tags: 'd1-pending',
    );

    test(
      'Python error in one call does not affect the next call',
      () async {
        await expectLater(
          session.execute('1 / 0').result,
          throwsA(isA<MontyError>()),
        );

        // Next call is a clean interpreter — basic arithmetic works.
        final result = await session.execute('1 + 1').result;
        expect(result.dartValue, 2);
      },
      tags: 'd1-pending',
    );

    test(
      'many sequential execute() calls work',
      () async {
        for (var i = 0; i < 10; i++) {
          final r = await session.execute('$i * 2').result;
          expect(r.dartValue, i * 2);
        }
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime plugin lifecycle (#296)', () {
    test(
      'dispose() calls onDispose on shared-mode plugins',
      () async {
        // Regression test for #296 — dispose() never called
        // ExtensionCoordinator.disposeAll().
        //
        // Without the fix, _onDisposeCalled stays false after dispose().
        // With the fix, disposeAll() propagates to each plugin's onDispose().
        final plugin = _TrackingExtension();
        final session = await MontyRuntime.start(extensions: [plugin]);

        await session.execute('pass').result; // triggers attachTo
        await session.dispose();

        expect(
          plugin.onDisposeCalled,
          isTrue,
          reason: 'plugin.onDispose must be called when session is disposed',
        );
      },
      tags: 'd1-pending',
    );

    test('dispose() calls onDispose even without prior execute()', () async {
      // Plugins registered but never attached (no execute() called) must
      // still have onDispose called — disposeAll() iterates _extensions when
      // _attachOrder is null, so this works once disposeAll() is invoked.
      final plugin = _TrackingExtension();
      final session = await MontyRuntime.start(extensions: [plugin]);

      await session.dispose();

      expect(
        plugin.onDisposeCalled,
        isTrue,
        reason: 'onDispose must be called even without a prior execute()',
      );
    });

    test(
      'sandbox mode: plugin onDispose called after each execute()',
      () async {
        // In sandbox mode a fresh ExtensionCoordinator is created per
        // execute() and must be disposed in the finally block regardless of
        // success or error.
        final plugin = _TrackingExtension();
        final session = await MontyRuntime.start(
          sandbox: true,
          extensions: [plugin],
        );
        addTearDown(session.dispose);

        await session.execute('pass').result;
        expect(plugin.disposeCount, 1);

        await session.execute('pass').result;
        expect(
          plugin.disposeCount,
          2,
          reason:
              'each sandboxed execute() must dispose its per-call coordinator',
        );
      },
      tags: 'd1-pending',
    );

    test(
      'sandbox mode: plugin onDispose called even when execute() throws',
      () async {
        // The finally block must run even on error — verifies no leak when
        // Python raises an exception.
        final plugin = _TrackingExtension();
        final session = await MontyRuntime.start(
          sandbox: true,
          extensions: [plugin],
        );
        addTearDown(session.dispose);

        await expectLater(
          session.execute('raise ValueError("boom")').result,
          throwsA(isA<MontyError>()),
        );

        expect(
          plugin.disposeCount,
          1,
          reason: 'registry must be disposed even when Python raises',
        );
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime event streaming', () {
    test(
      'execute().events emits events',
      () async {
        final session = await MontyRuntime.start();

        // First execute to ensure attached
        await session.execute('pass').result;

        final events = await session.execute('2 + 2').events.toList();

        expect(events, isNotEmpty);
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));

        await session.dispose();
      },
      tags: 'd1-pending',
    );

    test(
      'execute().events attaches plugins without prior execute()',
      () async {
        final session = await MontyRuntime.start(
          extensions: [TemplateStubExtension()],
        );
        addTearDown(session.dispose);

        // Call execute().events as the FIRST operation — no prior .result
        // await.
        // Before the fix, this would fail with "Unknown function: tmpl_render"
        // because the events-only path skipped _ensureSharedAttached().
        final events = await session
            .execute(
              'tmpl_render(template="Hello {{ name }}!", '
              'context={"name": "test"})',
            )
            .events
            .toList();

        final finished = events.whereType<BridgeRunFinished>().single;
        expect(finished.value, 'Hello test!');
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime.invoke', () {
    test(
      'invokes a registered host function',
      () async {
        final session = await MontyRuntime.start();
        addTearDown(session.dispose);
        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'shout',
              description: '',
              params: [HostParam(name: 'msg', type: HostParamType.string)],
            ),
            handler: (args, _) async => (args['msg']! as String).toUpperCase(),
          ),
        );

        final result = await session.invoke('shout', const {'msg': 'hi'});

        expect(result, 'HI');
      },
      tags: 'd1-pending',
    );

    test('sandbox mode throws UnsupportedError', () async {
      final session = await MontyRuntime.start(sandbox: true);
      addTearDown(session.dispose);

      await expectLater(
        session.invoke('anything', const {}),
        throwsUnsupportedError,
      );
    });

    test(
      'unknown function throws ArgumentError',
      () async {
        final session = await MontyRuntime.start();
        addTearDown(session.dispose);

        await expectLater(
          session.invoke('nope', const {}),
          throwsArgumentError,
        );
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime.coordinator', () {
    test('shared mode: non-null after construction', () async {
      final session = await MontyRuntime.start();
      addTearDown(session.dispose);
      expect(session.coordinator, isNotNull);
    });

    test('shared mode: is ExtensionCoordinator', () async {
      final session = await MontyRuntime.start();
      addTearDown(session.dispose);
      expect(session.coordinator, isA<ExtensionCoordinator>());
    });

    test('shared mode: stable reference across repeated access', () async {
      final session = await MontyRuntime.start();
      addTearDown(session.dispose);
      expect(session.coordinator, same(session.coordinator));
    });

    test('sandbox mode: null', () async {
      final session = await MontyRuntime.start(sandbox: true);
      addTearDown(session.dispose);
      expect(session.coordinator, isNull);
    });

    test(
      'shared mode: registered extensions are visible on coordinator',
      () async {
        final ext = TemplateStubExtension();
        final session = await MontyRuntime.start(extensions: [ext]);
        addTearDown(session.dispose);
        expect(
          session.coordinator!.extensions.map((e) => e.namespace),
          contains('tmpl'),
        );
      },
    );

    test(
      'clearState() produces a new non-null coordinator',
      () async {
        final session = await MontyRuntime.start();
        addTearDown(session.dispose);
        final before = session.coordinator;
        await session.clearState();
        final after = session.coordinator;
        expect(after, isNotNull);
        expect(after, isNot(same(before)));
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime.execute inputs injection', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start();
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'string input is visible as a Python variable',
      () async {
        final result = await session
            .execute('greeting', inputs: {'greeting': 'hello'})
            .result;

        expect(result.dartValue, 'hello');
      },
      tags: 'd1-pending',
    );

    test(
      'int input is visible as a Python variable',
      () async {
        final result = await session.execute('x * 2', inputs: {'x': 21}).result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'multiple inputs are all visible',
      () async {
        final result = await session
            .execute(
              'f"{say}, {target}!"',
              inputs: {'say': 'hi', 'target': 'alan'},
            )
            .result;

        expect(result.dartValue, 'hi, alan!');
      },
      tags: 'd1-pending',
    );

    test(
      'null inputs param is a no-op',
      () async {
        final result = await session.execute('1 + 1').result;

        expect(result.dartValue, 2);
      },
      tags: 'd1-pending',
    );

    test(
      'shared mode: injected inputs persist as Python globals',
      () async {
        // In shared mode, inputsToCode() prepends `temp = 99` as an assignment,
        // so `temp` lives in the module globals and remains visible on the next
        // execute() call — which is expected shared-interpreter behaviour.
        await session.execute('pass', inputs: {'temp': 99}).result;
        final result = await session.execute('temp').result;

        expect(result.dartValue, 99);
      },
      tags: 'd1-pending',
    );

    test(
      'sandbox mode: inputs injected per call',
      () async {
        final sandbox = await MontyRuntime.start(sandbox: true);
        addTearDown(sandbox.dispose);

        final r1 = await sandbox
            .execute('name', inputs: {'name': 'alice'})
            .result;
        final r2 = await sandbox
            .execute('name', inputs: {'name': 'bob'})
            .result;

        expect(r1.dartValue, 'alice');
        expect(r2.dartValue, 'bob');
      },
      tags: 'd1-pending',
    );

    // inputs is a named (kwargs-only) Dart parameter — no positional form
    // exists in the API. The tests below confirm the named-only contract
    // is enforced end-to-end.
    test(
      'inputs named param: omitting inputs is valid',
      () async {
        final result = await session.execute('7 * 6').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'Dart null value in inputs binds Python None',
      () async {
        // MontyValue.fromDart(null) is MontyNone, so a null input is None.
        final result = await session.execute('x', inputs: {'x': null}).result;

        expect(result, isA<MontyNone>());
      },
      tags: 'd1-pending',
    );

    test(
      'unsupported value type in inputs throws ArgumentError',
      () {
        // toPythonLiteral rejects arbitrary Dart objects (DateTime, custom
        // classes, etc.) — only the documented set is convertible.
        expect(
          () => session.execute('x', inputs: {'x': Object()}),
          throwsA(isA<ArgumentError>()),
        );
      },
      tags: 'd1-pending',
    );

    test(
      'inputs named param: null inputs is a no-op',
      () async {
        // Explicitly passing `inputs: null` is the contract under test here;
        // the redundant-default lint would defeat the test's purpose.
        // ignore: avoid_redundant_argument_values
        final result = await session.execute('1 + 1', inputs: null).result;

        expect(result.dartValue, 2);
      },
      tags: 'd1-pending',
    );
  });

  group('MontyRuntime.execute return-value semantics', () {
    late MontyRuntime session;

    setUp(() async {
      session = await MontyRuntime.start();
    });

    tearDown(() async {
      await session.dispose();
    });

    test(
      'last expression is captured as result value',
      () async {
        final result = await session.execute('x + 1', inputs: {'x': 41}).result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'assignment statement yields MontyNone — not the assigned value',
      () async {
        final result = await session.execute('x = 42').result;

        // Assignment is a statement; no last-expression value.
        expect(result.dartValue, isNull);
      },
      tags: 'd1-pending',
    );

    test(
      'expression after assignment is the result',
      () async {
        final result = await session.execute('x = 7\nx * 6').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );

    test(
      'module-level return yields the return value',
      () async {
        // pydantic-monty treats module-level `return` as a valid return
        // statement — it returns the value rather than raising SyntaxError.
        final result = await session.execute('return 42').result;

        expect(result.dartValue, 42);
      },
      tags: 'd1-pending',
    );
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Plugin that records how many times [onDispose] was called.
class _TrackingExtension extends MontyExtension {
  bool onDisposeCalled = false;
  int disposeCount = 0;

  @override
  String get namespace => 'track';

  @override
  List<HostFunction> get functions => [];

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    onDisposeCalled = true;
    disposeCount++;
  }
}
