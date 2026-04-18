@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

/// Integration tests for AgentSession — requires the native Monty library.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/agent_session_test.dart
/// ```
void main() {
  group('AgentSession stateful execution', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('simple expression', () async {
      final result = await session.execute('2 + 2');

      expect(result.value.dartValue, 4);
    });

    test('variables persist across execute() calls', () async {
      await session.execute('x = 42');
      await session.execute('y = x * 2');
      final result = await session.execute('x + y');

      expect(result.value.dartValue, 126);
    });

    test('string variables persist', () async {
      await session.execute('name = "monty"');
      final result = await session.execute('name.upper()');

      expect(result.value.dartValue, 'MONTY');
    });

    test('list variables persist', () async {
      await session.execute('data = [1, 2, 3]');
      await session.execute('data.append(4)');
      final result = await session.execute('sum(data)');

      expect(result.value.dartValue, 10);
    });

    test('dict variables persist', () async {
      await session.execute('config = {"debug": True, "level": 5}');
      final result = await session.execute('config["debug"]');

      expect(result.value.dartValue, true);
    });

    test('clearState() resets all variables', () async {
      await session.execute('x = 42');
      session.clearState();
      final result = await session.execute('x');

      expect(result.error, isNotNull);
    });

    test('multiple types in state', () async {
      await session.execute('a = 1; b = 2.5; c = "hello"; d = True');
      final result = await session.execute('[a, b, c, d]');

      expect(result.value.dartValue, [1, 2.5, 'hello', true]);
    });

    // Regression: augmented assignment previously caused SyntaxError because
    // captureLastExpression wrapped `x += 1` as `__r = (x += 1)` — invalid
    // Python.
    test('augmented assignment (x += 1) does not error', () async {
      await session.execute('x = 10');
      final result = await session.execute('x += 1');

      expect(result.error, isNull);
      final val = await session.execute('x');
      expect(val.value.dartValue, 11);
    });

    // Regression: functions were previously coerced to their string repr by the
    // persist→restore round-trip and became NameError on the second call.
    test('function defined in one call callable in next', () async {
      await session.execute('def add(a, b): return a + b');
      final result = await session.execute('add(3, 4)');

      expect(result.error, isNull);
      expect(result.value.dartValue, 7);
    });
  });

  group('AgentSession with host functions', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession();
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
          handler: (args) async => (args['n']! as int) * 2,
        ),
      );

      final result = await session.execute('double_it(21)');

      expect(result.value.dartValue, 42);
    });

    test('host function result persists in state', () async {
      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'get_data',
            description: 'Returns sample data',
          ),
          handler: (_) async => [1, 2, 3, 4, 5],
        ),
      );

      await session.execute('data = get_data()');
      final result = await session.execute('sum(data)');

      expect(result.value.dartValue, 15);
    });

    test('schemas include registered functions', () {
      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'my_tool',
            description: 'A custom tool',
          ),
          handler: (_) async => null,
        ),
      );

      final names = session.schemas.map((s) => s.name).toList();

      expect(names, contains('my_tool'));
      expect(names, contains('__restore_state__'));
      expect(names, contains('__persist_state__'));
    });
  });

  group('AgentSession with filesystem', () {
    late AgentSession session;

    setUp(() {
      // Use memory filesystem for these tests (not LocalFileSystem)
      final time = timeHandler();
      session = AgentSession(
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
      await session.execute(
        'from pathlib import Path\n'
        'Path("/data/test.txt").write_text("hello from agent")',
      );
      final result = await session.execute(
        'from pathlib import Path\n'
        'Path("/data/test.txt").read_text()',
      );

      expect(result.value.dartValue, 'hello from agent');
    });

    test('filesystem state persists across calls', () async {
      await session.execute(
        'from pathlib import Path\n'
        'Path("/data").mkdir(parents=True, exist_ok=True)\n'
        'Path("/data/counter.txt").write_text("0")',
      );

      await session.execute(
        'from pathlib import Path\n'
        'n = int(Path("/data/counter.txt").read_text())\n'
        'Path("/data/counter.txt").write_text(str(n + 1))',
      );

      final result = await session.execute(
        'from pathlib import Path\n'
        'int(Path("/data/counter.txt").read_text())',
      );

      expect(result.value.dartValue, 1);
    });

    test('date.today() returns reasonable year', () async {
      // Note: date objects stored in state are not JSON-serializable,
      // so we extract the year immediately rather than persisting.
      final result = await session.execute(
        'from datetime import date\n'
        'date.today().year >= 2024',
      );

      expect(result.value.dartValue, true);
    });
  });

  group('AgentSession error handling', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('Python error returns error result', () async {
      final result = await session.execute('1 / 0');

      expect(result.error, isNotNull);
    });

    test('error does not break state', () async {
      await session.execute('x = 42');
      await session.execute('1 / 0'); // error, but x should survive
      final result = await session.execute('x');

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

  group('AgentSession sandbox mode', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession(sandbox: true);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('simple expression', () async {
      final result = await session.execute('2 + 2');

      expect(result.value.dartValue, 4);
    });

    test('isSandboxMode is true', () {
      expect(session.isSandboxMode, isTrue);
    });

    // Sandbox mode creates a fresh MontyRepl per execute() call — state does
    // NOT persist between calls (no restore/persist serialization).
    test('each execute() is isolated — variables do not carry over', () async {
      await session.execute('x = 42');
      final result = await session.execute('x + 1');

      // x is not defined in the second fresh interpreter; expect an error.
      expect(result.error, isNotNull);
    });

    test('consecutive calls each run in an independent fresh interpreter',
        () async {
      final r1 = await session.execute('2 + 2');
      final r2 = await session.execute('3 + 3');

      expect(r1.value.dartValue, 4);
      expect(r2.value.dartValue, 6);
    });

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
          handler: (args) async => (args['n']! as int) * 2,
        ),
      );

      final result = await session.execute('double_it(21)');

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
          handler: (args) async => 'Hello, ${args['name']}!',
        ),
      );

      // Both the call and the result access are in the same execute() call.
      final result = await session.execute('greet("World")');

      expect(result.value.dartValue, 'Hello, World!');
    });

    test('clearState() is a no-op — sandbox already starts fresh', () async {
      await session.execute('x = 99');
      session.clearState(); // no-op in sandbox mode
      // x was never going to be visible in a fresh interpreter anyway
      final result = await session.execute('''
try:
    result = x
except NameError:
    result = "gone"
result
''');

      expect(result.value.dartValue, 'gone');
    });

    test('Python error in one call does not affect the next call', () async {
      final errResult = await session.execute('1 / 0');
      expect(errResult.error, isNotNull);

      // Next call is a clean interpreter — basic arithmetic works.
      final result = await session.execute('1 + 1');
      expect(result.value.dartValue, 2);
    });

    test('executeStream throws in sandbox mode', () {
      expect(
        () => session.executeStream('1 + 1'),
        throwsUnsupportedError,
      );
    });

    test('many sequential execute() calls work', () async {
      for (var i = 0; i < 10; i++) {
        final r = await session.execute('$i * 2');
        expect(r.value.dartValue, i * 2);
      }
    });
  });

  group('AgentSession plugin lifecycle (#296)', () {
    test('dispose() calls onDispose on shared-mode plugins', () async {
      // Regression test for #296 — dispose() never called
      // PluginRegistry.disposeAll().
      //
      // Without the fix, _onDisposeCalled stays false after dispose().
      // With the fix, disposeAll() propagates to each plugin's onDispose().
      final plugin = _TrackingPlugin();
      final session = AgentSession(plugins: [plugin]);

      await session.execute('pass'); // triggers attachTo
      await session.dispose();

      expect(
        plugin.onDisposeCalled,
        isTrue,
        reason: 'plugin.onDispose must be called when session is disposed',
      );
    });

    test('dispose() calls onDispose even without prior execute()', () async {
      // Plugins registered but never attached (no execute() called) must
      // still have onDispose called — disposeAll() iterates _plugins when
      // _attachOrder is null, so this works once disposeAll() is invoked.
      final plugin = _TrackingPlugin();
      final session = AgentSession(plugins: [plugin]);

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
        // In sandbox mode a fresh PluginRegistry is created per execute() and
        // must be disposed in the finally block regardless of success or error.
        final plugin = _TrackingPlugin();
        final session = AgentSession(sandbox: true, plugins: [plugin]);
        addTearDown(session.dispose);

        await session.execute('pass');
        expect(plugin.disposeCount, 1);

        await session.execute('pass');
        expect(
          plugin.disposeCount,
          2,
          reason: 'each sandboxed execute() must dispose its per-call registry',
        );
      },
    );

    test(
      'sandbox mode: plugin onDispose called even when execute() throws',
      () async {
        // The finally block must run even on error — verifies no leak when
        // Python raises an exception.
        final plugin = _TrackingPlugin();
        final session = AgentSession(sandbox: true, plugins: [plugin]);
        addTearDown(session.dispose);

        await session.execute('raise ValueError("boom")');

        expect(
          plugin.disposeCount,
          1,
          reason: 'registry must be disposed even when Python raises',
        );
      },
    );
  });

  // sessionStateSignal is a Dart-side mirror of Python globals retained for
  // API compatibility. With ReplPlatform backing, state lives natively in the
  // Rust REPL heap — the signal always emits an empty map.
  group('AgentSession.sessionStateSignal', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession();
    });

    tearDown(() async {
      await session.dispose();
    });

    test('always an empty map — state lives in Rust REPL heap', () async {
      await session.execute('x = 42');
      await session.execute('y = 99');

      // Signal is not populated — state is in the native REPL, not Dart.
      expect(session.sessionStateSignal.value, isEmpty);
    });

    test('clearState() resets signal to empty map', () async {
      session.clearState();

      expect(session.sessionStateSignal.value, isEmpty);
    });

    test('is a ReadonlySignal', () {
      expect(
        session.sessionStateSignal,
        isA<ReadonlySignal<Map<String, Object?>>>(),
      );
    });
  });

  group('AgentSession.sessionStateSignal sandbox mode', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession(sandbox: true);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('always empty — sandbox calls use fresh interpreters', () async {
      await session.execute('x = 99');
      await session.execute('y = 20');

      expect(session.sessionStateSignal.value, isEmpty);
    });
  });

  group('AgentSession event streaming', () {
    test('executeStream emits events', () async {
      final session = AgentSession();

      // First execute to ensure attached
      await session.execute('pass');

      final events = await session.executeStream('2 + 2').toList();

      expect(events, isNotEmpty);
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));

      await session.dispose();
    });

    test('executeStream attaches plugins without prior execute()', () async {
      final session = AgentSession(
        plugins: [JinjaTemplatePlugin()],
      );
      addTearDown(session.dispose);

      // Call executeStream as the FIRST operation — no prior execute().
      // Before the fix, this would fail with "Unknown function: tmpl_render"
      // because executeStream() skipped _ensureSharedAttached().
      final events = await session
          .executeStream(
            'tmpl_render(template="Hello {{ name }}!", '
            'context={"name": "test"})',
          )
          .toList();

      final finished = events.whereType<BridgeRunFinished>().single;
      expect(finished.value, 'Hello test!');
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Plugin that records how many times [onDispose] was called.
class _TrackingPlugin extends MontyPlugin {
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
