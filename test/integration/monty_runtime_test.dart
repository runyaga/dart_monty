@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

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

    setUp(() {
      session = MontyRuntime();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('simple expression', () async {
      final result = await session.execute('2 + 2').result;

      expect(result.value.dartValue, 4);
    });

    test('variables persist across execute() calls', () async {
      await session.execute('x = 42').result;
      await session.execute('y = x * 2').result;
      final result = await session.execute('x + y').result;

      expect(result.value.dartValue, 126);
    });

    test('string variables persist', () async {
      await session.execute('name = "monty"').result;
      final result = await session.execute('name.upper()').result;

      expect(result.value.dartValue, 'MONTY');
    });

    test('list variables persist', () async {
      await session.execute('data = [1, 2, 3]').result;
      await session.execute('data.append(4)').result;
      final result = await session.execute('sum(data)').result;

      expect(result.value.dartValue, 10);
    });

    test('dict variables persist', () async {
      await session.execute('config = {"debug": True, "level": 5}').result;
      final result = await session.execute('config["debug"]').result;

      expect(result.value.dartValue, true);
    });

    test('clearState() resets all variables', () async {
      await session.execute('x = 42').result;
      session.clearState();
      final result = await session.execute('x').result;

      expect(result.error, isNotNull);
    });

    test('multiple types in state', () async {
      await session.execute('a = 1; b = 2.5; c = "hello"; d = True').result;
      final result = await session.execute('[a, b, c, d]').result;

      expect(result.value.dartValue, [1, 2.5, 'hello', true]);
    });

    // Regression: augmented assignment previously caused SyntaxError because
    // captureLastExpression wrapped `x += 1` as `__r = (x += 1)` — invalid
    // Python.
    test('augmented assignment (x += 1) does not error', () async {
      await session.execute('x = 10').result;
      final result = await session.execute('x += 1').result;

      expect(result.error, isNull);
      final val = await session.execute('x').result;
      expect(val.value.dartValue, 11);
    });

    // Regression: functions were previously coerced to their string repr by the
    // persist→restore round-trip and became NameError on the second call.
    test('function defined in one call callable in next', () async {
      await session.execute('def add(a, b): return a + b').result;
      final result = await session.execute('add(3, 4)').result;

      expect(result.error, isNull);
      expect(result.value.dartValue, 7);
    });
  });

  group('MontyRuntime with host functions', () {
    late MontyRuntime session;

    setUp(() {
      session = MontyRuntime();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('registered host function callable from Python', () async {
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

      expect(result.value.dartValue, 42);
    });

    test('host function result persists in state', () async {
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

      expect(result.value.dartValue, 15);
    });

    test('schemas include registered functions', () {
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
    });
  });

  group('MontyRuntime with filesystem', () {
    late MontyRuntime session;

    setUp(() {
      // Use memory filesystem for these tests (not LocalFileSystem)
      final time = timeHandler();
      session = MontyRuntime(
        osHandlers: {
          'Path.': memoryFsHandler(),
          'date.': time,
          'datetime.': time,
        },
      );
    });

    tearDown(() async {
      await session.dispose();
    });

    test('write and read file via pathlib', () async {
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

      expect(result.value.dartValue, 'hello from agent');
    });

    test('filesystem state persists across calls', () async {
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

      expect(result.value.dartValue, 1);
    });

    test('date.today() returns reasonable year', () async {
      // Note: date objects stored in state are not JSON-serializable,
      // so we extract the year immediately rather than persisting.
      final result = await session
          .execute(
            'from datetime import date\n'
            'date.today().year >= 2024',
          )
          .result;

      expect(result.value.dartValue, true);
    });
  });

  group('MontyRuntime error handling', () {
    late MontyRuntime session;

    setUp(() {
      session = MontyRuntime();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('Python error returns error result', () async {
      final result = await session.execute('1 / 0').result;

      expect(result.error, isNotNull);
    });

    test('error does not break state', () async {
      await session.execute('x = 42').result;
      await session.execute('1 / 0').result; // error, but x should survive
      final result = await session.execute('x').result;

      expect(result.value.dartValue, 42);
    });

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

    setUp(() {
      session = MontyRuntime(sandbox: true);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('simple expression', () async {
      final result = await session.execute('2 + 2').result;

      expect(result.value.dartValue, 4);
    });

    test('isSandboxMode is true', () {
      expect(session.isSandboxMode, isTrue);
    });

    // Sandbox mode creates a fresh MontyRepl per execute() call — state does
    // NOT persist between calls (no restore/persist serialization).
    test('each execute() is isolated — variables do not carry over', () async {
      await session.execute('x = 42').result;
      final result = await session.execute('x + 1').result;

      // x is not defined in the second fresh interpreter; expect an error.
      expect(result.error, isNotNull);
    });

    test(
      'consecutive calls each run in an independent fresh interpreter',
      () async {
        final r1 = await session.execute('2 + 2').result;
        final r2 = await session.execute('3 + 3').result;

        expect(r1.value.dartValue, 4);
        expect(r2.value.dartValue, 6);
      },
    );

    test('host function callable from sandbox', () async {
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

      expect(result.value.dartValue, 42);
    });

    test('host function available within same call', () async {
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

      expect(result.value.dartValue, 'Hello, World!');
    });

    test('clearState() is a no-op — sandbox already starts fresh', () async {
      await session.execute('x = 99').result;
      session.clearState(); // no-op in sandbox mode
      // x was never going to be visible in a fresh interpreter anyway
      final result = await session.execute('''
try:
    result = x
except NameError:
    result = "gone"
result
''').result;

      expect(result.value.dartValue, 'gone');
    });

    test('Python error in one call does not affect the next call', () async {
      final errResult = await session.execute('1 / 0').result;
      expect(errResult.error, isNotNull);

      // Next call is a clean interpreter — basic arithmetic works.
      final result = await session.execute('1 + 1').result;
      expect(result.value.dartValue, 2);
    });

    test('many sequential execute() calls work', () async {
      for (var i = 0; i < 10; i++) {
        final r = await session.execute('$i * 2').result;
        expect(r.value.dartValue, i * 2);
      }
    });
  });

  group('MontyRuntime plugin lifecycle (#296)', () {
    test('dispose() calls onDispose on shared-mode plugins', () async {
      // Regression test for #296 — dispose() never called
      // ExtensionCoordinator.disposeAll().
      //
      // Without the fix, _onDisposeCalled stays false after dispose().
      // With the fix, disposeAll() propagates to each plugin's onDispose().
      final plugin = _TrackingExtension();
      final session = MontyRuntime(extensions: [plugin]);

      await session.execute('pass').result; // triggers attachTo
      await session.dispose();

      expect(
        plugin.onDisposeCalled,
        isTrue,
        reason: 'plugin.onDispose must be called when session is disposed',
      );
    });

    test('dispose() calls onDispose even without prior execute()', () async {
      // Plugins registered but never attached (no execute() called) must
      // still have onDispose called — disposeAll() iterates _extensions when
      // _attachOrder is null, so this works once disposeAll() is invoked.
      final plugin = _TrackingExtension();
      final session = MontyRuntime(extensions: [plugin]);

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
        final session = MontyRuntime(sandbox: true, extensions: [plugin]);
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
    );

    test(
      'sandbox mode: plugin onDispose called even when execute() throws',
      () async {
        // The finally block must run even on error — verifies no leak when
        // Python raises an exception.
        final plugin = _TrackingExtension();
        final session = MontyRuntime(sandbox: true, extensions: [plugin]);
        addTearDown(session.dispose);

        await session.execute('raise ValueError("boom")').result;

        expect(
          plugin.disposeCount,
          1,
          reason: 'registry must be disposed even when Python raises',
        );
      },
    );
  });

  group('MontyRuntime event streaming', () {
    test('execute().events emits events', () async {
      final session = MontyRuntime();

      // First execute to ensure attached
      await session.execute('pass').result;

      final events = await session.execute('2 + 2').events.toList();

      expect(events, isNotEmpty);
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      await session.dispose();
    });

    test('execute().events attaches plugins without prior execute()', () async {
      final session = MontyRuntime(
        extensions: [JinjaTemplateExtension()],
      );
      addTearDown(session.dispose);

      // Call execute().events as the FIRST operation — no prior .result await.
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
    });
  });

  group('MontyRuntime.invoke', () {
    test('invokes a registered host function and runs interceptor', () async {
      var interceptorCalls = 0;
      String? seenName;
      Map<String, Object?>? seenArgs;
      final session = MontyRuntime(
        interceptor: (name, args, next) {
          interceptorCalls++;
          seenName = name;
          seenArgs = args;
          return next();
        },
      );
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
      expect(interceptorCalls, 1);
      expect(seenName, 'shout');
      expect(seenArgs, const {'msg': 'hi'});
    });

    test('sandbox mode throws UnsupportedError', () async {
      final session = MontyRuntime(sandbox: true);
      addTearDown(session.dispose);

      await expectLater(
        session.invoke('anything', const {}),
        throwsUnsupportedError,
      );
    });

    test('unknown function throws ArgumentError', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      await expectLater(
        session.invoke('nope', const {}),
        throwsArgumentError,
      );
    });
  });

  group('MontyRuntime.coordinator', () {
    test('shared mode: non-null after construction', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);
      expect(session.coordinator, isNotNull);
    });

    test('shared mode: is ExtensionCoordinator', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);
      expect(session.coordinator, isA<ExtensionCoordinator>());
    });

    test('shared mode: stable reference across repeated access', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);
      expect(session.coordinator, same(session.coordinator));
    });

    test('sandbox mode: null', () async {
      final session = MontyRuntime(sandbox: true);
      addTearDown(session.dispose);
      expect(session.coordinator, isNull);
    });

    test(
      'shared mode: registered extensions are visible on coordinator',
      () async {
        final ext = JinjaTemplateExtension();
        final session = MontyRuntime(extensions: [ext]);
        addTearDown(session.dispose);
        expect(
          session.coordinator!.extensions.map((e) => e.namespace),
          contains('tmpl'),
        );
      },
    );

    test('clearState() produces a new non-null coordinator', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);
      final before = session.coordinator;
      session.clearState();
      final after = session.coordinator;
      expect(after, isNotNull);
      expect(after, isNot(same(before)));
    });
  });

  group('MontyRuntime.execute inputs injection', () {
    late MontyRuntime session;

    setUp(() {
      session = MontyRuntime();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('string input is visible as a Python variable', () async {
      final result = await session
          .execute('greeting', inputs: {'greeting': 'hello'})
          .result;

      expect(result.value.dartValue, 'hello');
    });

    test('int input is visible as a Python variable', () async {
      final result = await session.execute('x * 2', inputs: {'x': 21}).result;

      expect(result.value.dartValue, 42);
    });

    test('multiple inputs are all visible', () async {
      final result = await session
          .execute(
            'f"{say}, {target}!"',
            inputs: {'say': 'hi', 'target': 'alan'},
          )
          .result;

      expect(result.value.dartValue, 'hi, alan!');
    });

    test('null inputs param is a no-op', () async {
      final result = await session.execute('1 + 1').result;

      expect(result.value.dartValue, 2);
    });

    test('inputs do not bleed into the next execute() call', () async {
      await session.execute('pass', inputs: {'temp': 99}).result;
      final result = await session.execute('temp').result;

      // temp is not re-injected; Python raises NameError.
      expect(result.error, isNotNull);
    });

    test('sandbox mode: inputs injected per call', () async {
      final sandbox = MontyRuntime(sandbox: true);
      addTearDown(sandbox.dispose);

      final r1 = await sandbox
          .execute('name', inputs: {'name': 'alice'})
          .result;
      final r2 = await sandbox.execute('name', inputs: {'name': 'bob'}).result;

      expect(r1.value.dartValue, 'alice');
      expect(r2.value.dartValue, 'bob');
    });
  });

  group('MontyRuntime.descriptionProvider', () {
    test('overrides function description on registered extension', () async {
      final session = MontyRuntime(
        extensions: [JinjaTemplateExtension()],
        descriptionProvider: (name) => 'custom: $name',
      );
      addTearDown(session.dispose);
      await session.execute('pass').result;
      final schema = session.schemas.firstWhere((s) => s.name == 'tmpl_render');
      expect(schema.description, 'custom: tmpl_render');
    });

    test('null return from provider leaves description unchanged', () async {
      final session = MontyRuntime(
        extensions: [JinjaTemplateExtension()],
        descriptionProvider: (_) => null,
      );
      addTearDown(session.dispose);
      await session.execute('pass').result;
      final schema = session.schemas.firstWhere((s) => s.name == 'tmpl_render');
      expect(schema.description, isNotEmpty);
      expect(schema.description, isNot(startsWith('custom:')));
    });
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
