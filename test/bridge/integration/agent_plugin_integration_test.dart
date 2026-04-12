@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Integration tests for AgentSession with plugins — requires native FFI.
///
/// Tests the full stack: AgentSession + plugins + real Monty interpreter.
/// Covers the same scenarios validated in the browser agent demo.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/agent_plugin_integration_test.dart
/// ```
void main() {
  // ---------------------------------------------------------------------------
  // Template plugin
  // ---------------------------------------------------------------------------

  group('AgentSession + DinjaTemplatePlugin', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession(plugins: [DinjaTemplatePlugin()]);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('tmpl_render with variables', () async {
      final result = await session.execute(
        "tmpl_render(template='Hello {{ name }}!', "
        "context={'name': 'Alice'})",
      );

      expect(result.value?.dartValue, 'Hello Alice!');
    });

    test('tmpl_render with loop', () async {
      final result = await session.execute(
        "tmpl_render("
        "template='{% for x in items %}{{ x }} {% endfor %}',"
        "context={'items': ['a', 'b', 'c']})",
      );

      expect(result.value?.dartValue, 'a b c ');
    });

    test('tmpl_render with conditional', () async {
      final result = await session.execute(
        "tmpl_render("
        "template='{% if n > 10 %}big{% else %}small{% endif %}',"
        "context={'n': 42})",
      );

      expect(result.value?.dartValue, 'big');
    });
  });

  // ---------------------------------------------------------------------------
  // Message bus plugin
  // ---------------------------------------------------------------------------

  group('AgentSession + MessageBusPlugin', () {
    late AgentSession session;

    setUp(() {
      session = AgentSession(plugins: [MessageBusPlugin()]);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('send and receive FIFO', () async {
      await session.execute(
        "msg_send(name='ch', message='first')\n"
        "msg_send(name='ch', message='second')",
      );
      final result = await session.execute(
        "[msg_recv(name='ch'), msg_recv(name='ch')]",
      );

      expect(result.value?.dartValue, ['first', 'second']);
    });

    test('peek returns None when empty', () async {
      final result = await session.execute("msg_peek(name='empty')");

      expect(result.value?.dartValue, isNull);
    });

    test('stats reports queue depth', () async {
      await session.execute(
        "msg_send(name='q', message=1)\n"
        "msg_send(name='q', message=2)",
      );
      final result = await session.execute("msg_stats(name='q')");
      final stats = result.value?.dartValue as Map;

      expect(stats['send_count'], 2);
      expect(stats['queue_depth'], 2);
    });
  });

  // ---------------------------------------------------------------------------
  // Sandbox plugin — child spawning
  // ---------------------------------------------------------------------------

  group('AgentSession + SandboxPlugin', () {
    late AgentSession session;

    setUp(() {
      final os = OsProvider.compose({
        'Path.': MemoryFsProvider(),
        'date.': TimeOsProvider(),
        'datetime.': TimeOsProvider(),
      });
      final tmpl = DinjaTemplatePlugin();
      final msg = MessageBusPlugin();
      final plugins = <MontyPlugin>[tmpl, msg];
      plugins.add(
        SandboxPlugin(
          platformFactory: () async => Monty(os: os).platform,
          parentPlugins: plugins,
          parentOs: os,
        ),
      );
      session = AgentSession(os: os, plugins: plugins);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('spawn and await child', () async {
      final result = await session.execute(
        "h = sandbox_spawn(code='2 + 3')\n"
        'sandbox_await(handle=h)',
      );

      expect(result.value?.dartValue, 5);
    });

    test('gather multiple children', () async {
      final result = await session.execute(
        "h1 = sandbox_spawn(code='10')\n"
        "h2 = sandbox_spawn(code='20')\n"
        "h3 = sandbox_spawn(code='30')\n"
        'sandbox_await_all(handles=[h1, h2, h3])',
      );

      expect(result.value?.dartValue, [10, 20, 30]);
    });

    test('child error propagates cleanly', () async {
      final result = await session.execute(
        "h = sandbox_spawn(code='1 / 0')\n"
        'try:\n'
        '    r = sandbox_await(handle=h)\n'
        'except Exception as e:\n'
        "    r = f'caught: {e}'\n"
        'r',
      );
      final val = result.value?.dartValue as String;

      expect(val, contains('ZeroDivisionError'));
    });

    test('child captures print output', () async {
      final result = await session.execute(
        'h = sandbox_spawn(code=\'print("hello")\\n42\')\n'
        'sandbox_await(handle=h)\n'
        'sandbox_get_output(handle=h)',
      );

      expect(result.value?.dartValue, contains('hello'));
    });

    test('child lifecycle: spawn, alive, await, free', () async {
      final result = await session.execute(
        "h = sandbox_spawn(code='99')\n"
        'r = sandbox_await(handle=h)\n'
        'alive = sandbox_is_alive(handle=h)\n'
        'sandbox_free(handle=h)\n'
        '[r, alive]',
      );

      expect(result.value?.dartValue, [99, false]);
    });
  });

  // ---------------------------------------------------------------------------
  // Cross-plugin: templates inside children
  // ---------------------------------------------------------------------------

  group('AgentSession cross-plugin inheritance', () {
    late AgentSession session;

    setUp(() {
      final os = OsProvider.compose({
        'Path.': MemoryFsProvider(),
        'date.': TimeOsProvider(),
        'datetime.': TimeOsProvider(),
      });
      final tmpl = DinjaTemplatePlugin();
      final msg = MessageBusPlugin();
      final plugins = <MontyPlugin>[tmpl, msg];
      plugins.add(
        SandboxPlugin(
          platformFactory: () async => Monty(os: os).platform,
          parentPlugins: plugins,
          parentOs: os,
        ),
      );
      session = AgentSession(os: os, plugins: plugins);
    });

    tearDown(() async {
      await session.dispose();
    });

    test('child can use tmpl_render', () async {
      final result = await session.execute(
        'h = sandbox_spawn(code=\''
        'tmpl_render(template="Hi {{ who }}!", context={"who": "child"})'
        "')\n"
        'sandbox_await(handle=h)',
      );

      expect(result.value?.dartValue, 'Hi child!');
    });

    test('child sends message to parent via shared bus', () async {
      final result = await session.execute(
        "msg_send(name='tasks', message='do X')\n"
        'h = sandbox_spawn(code=\''
        'task = msg_recv(name="tasks")\\n'
        'msg_send(name="results", message=f"done: {task}")\\n'
        "task')\n"
        'child_got = sandbox_await(handle=h)\n'
        "parent_got = msg_recv(name='results')\n"
        '[child_got, parent_got]',
      );

      expect(result.value?.dartValue, ['do X', 'done: do X']);
    });

    test('producer/consumer pipeline between children', () async {
      final result = await session.execute(
        'producer = sandbox_spawn(code=\''
        'for i in range(3):\\n'
        '    msg_send(name="pipe", message=f"item-{i}")\\n'
        '"done"\')\n'
        'consumer = sandbox_spawn(code=\''
        'items = []\\n'
        'for i in range(3):\\n'
        '    items.append(msg_recv(name="pipe"))\\n'
        "items')\n"
        'sandbox_await(handle=producer)\n'
        'sandbox_await(handle=consumer)',
      );
      final items = result.value?.dartValue as List;

      expect(items, ['item-0', 'item-1', 'item-2']);
    });

    test('child writes to isolated filesystem', () async {
      final result = await session.execute(
        'from pathlib import Path\n'
        "Path('/parent.txt').write_text('parent data')\n"
        'h = sandbox_spawn(code=\''
        'from pathlib import Path\\n'
        'Path("/child.txt").write_text("child data")\\n'
        "Path(\"/child.txt\").read_text()')\n"
        'child_result = sandbox_await(handle=h)\n'
        "parent_file = Path('/parent.txt').read_text()\n"
        '[child_result, parent_file]',
      );

      expect(result.value?.dartValue, ['child data', 'parent data']);
    });
  });
}
