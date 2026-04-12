@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
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

      expect(result.value?.dartValue, 4);
    });

    test('variables persist across execute() calls', () async {
      await session.execute('x = 42');
      await session.execute('y = x * 2');
      final result = await session.execute('x + y');

      expect(result.value?.dartValue, 126);
    });

    test('string variables persist', () async {
      await session.execute('name = "monty"');
      final result = await session.execute('name.upper()');

      expect(result.value?.dartValue, 'MONTY');
    });

    test('list variables persist', () async {
      await session.execute('data = [1, 2, 3]');
      await session.execute('data.append(4)');
      final result = await session.execute('sum(data)');

      expect(result.value?.dartValue, 10);
    });

    test('dict variables persist', () async {
      await session.execute('config = {"debug": True, "level": 5}');
      final result = await session.execute('config["debug"]');

      expect(result.value?.dartValue, true);
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

      expect(result.value?.dartValue, [1, 2.5, 'hello', true]);
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

      expect(result.value?.dartValue, 42);
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

      expect(result.value?.dartValue, 15);
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
      // Use MemoryFsProvider for filesystem tests (not LocalFileSystem)
      final time = TimeOsProvider();
      session = AgentSession(
        os: OsProvider.compose({
          'Path.': MemoryFsProvider(),
          'date.': time,
          'datetime.': time,
        }),
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

      expect(result.value?.dartValue, 'hello from agent');
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

      expect(result.value?.dartValue, 1);
    });

    test('date.today() returns reasonable year', () async {
      // Note: date objects stored in state are not JSON-serializable,
      // so we extract the year immediately rather than persisting.
      final result = await session.execute(
        'from datetime import date\n'
        'date.today().year >= 2024',
      );

      expect(result.value?.dartValue, true);
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

      expect(result.value?.dartValue, 42);
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

      expect(result.value?.dartValue, 4);
    });

    test('isSandboxMode is true', () {
      expect(session.isSandboxMode, isTrue);
    });

    test('variables persist across execute() calls', () async {
      await session.execute('x = 42');
      final result = await session.execute('x + 1');

      expect(result.value?.dartValue, 43);
    });

    test('state persists across fresh interpreters', () async {
      await session.execute('name = "alice"');
      await session.execute('age = 30');
      final result = await session.execute('[name, age]');

      expect(result.value?.dartValue, ['alice', 30]);
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

      expect(result.value?.dartValue, 42);
    });

    test('host function result persists in state', () async {
      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'greet',
            description: 'Returns greeting',
            params: [
              HostParam(name: 'name', type: HostParamType.string),
            ],
          ),
          handler: (args) async => 'Hello, ${args['name']}!',
        ),
      );

      await session.execute('msg = greet("World")');
      final result = await session.execute('msg');

      expect(result.value?.dartValue, 'Hello, World!');
    });

    test('clearState() resets all variables', () async {
      await session.execute('x = 99');
      session.clearState();
      final result = await session.execute('''
try:
    result = x
except NameError:
    result = "gone"
result
''');

      expect(result.value?.dartValue, 'gone');
    });

    test('error does not break state', () async {
      await session.execute('x = 42');
      await session.execute('1 / 0'); // error
      final result = await session.execute('x');

      expect(result.value?.dartValue, 42);
    });

    test('executeStream throws in sandbox mode', () {
      expect(
        () => session.executeStream('1 + 1'),
        throwsUnsupportedError,
      );
    });

    test('many sequential execute() calls work', () async {
      for (var i = 0; i < 10; i++) {
        await session.execute('x = $i');
      }
      final result = await session.execute('x');

      expect(result.value?.dartValue, 9);
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
        plugins: [DinjaTemplatePlugin()],
      );
      addTearDown(session.dispose);

      // Call executeStream as the FIRST operation — no prior execute().
      // Before the fix, this would fail with "Unknown function: tmpl_render"
      // because executeStream() skipped _ensureSharedAttached().
      final events = await session.executeStream(
        'tmpl_render(template="Hello {{ name }}!", '
        'context={"name": "test"})',
      ).toList();

      final finished = events.whereType<BridgeRunFinished>().single;
      expect(finished.value, 'Hello test!');
    });
  });
}
