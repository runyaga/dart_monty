// Tests use print for debug output during development.
// ignore_for_file: avoid_print
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/plugins/sandbox_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/template_plugin.dart';
import 'package:dart_monty/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

void main() {
  test('ReplSession: run simple expression', () async {
    final session = ReplSession();
    final r = await session.run('2 + 2');

    expect(r.value, const MontyInt(4));
    await session.dispose();
  });

  test('ReplSession: state persists across runs', () async {
    final session = ReplSession();
    await session.run('x = 42');
    final r = await session.run('x + 1');

    expect(r.value, const MontyInt(43));
    await session.dispose();
  });

  test('ReplSession: function persists across runs', () async {
    final session = ReplSession();
    await session.run('def double(n):\n    return n * 2');
    final r = await session.run('double(21)');

    expect(r.value, const MontyInt(42));
    await session.dispose();
  });

  test('ReplSession: tmpl_render via DinjaTemplatePlugin', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    final r = await session.run(
      "tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})",
    );

    expect(r.value, isA<MontyString>());
    expect((r.value as MontyString).value, 'Hello World!');
    await session.dispose();
  });

  test('ReplSession: tmpl_render with Python-computed context', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    await session.run('scores = [85, 92, 78, 95, 88]');
    await session.run(
      "report = {'avg': sum(scores) / len(scores), 'top': max(scores)}",
    );
    final r = await session.run(
      "tmpl_render(template='avg={{ avg }}, top={{ top }}', context=report)",
    );

    expect(r.value, isA<MontyString>());
    expect((r.value as MontyString).value, 'avg=87.6, top=95');
    await session.dispose();
  });

  test('ReplSession: tmpl_render with for loop', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    await session.run("items = ['Alice', 'Bob']");
    final r = await session.run(
      'tmpl_render('
      "template='{% for u in items %}{{ u }} {% endfor %}', "
      "context={'items': items})",
    );

    expect(r.value, isA<MontyString>());
    expect(
      (r.value as MontyString).value,
      contains('Alice'),
    );
    await session.dispose();
  });

  test('ReplSession: execute returns BridgeEvent stream', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    final events = await session
        .execute(
          "tmpl_render(template='hi {{ x }}', context={'x': 1})",
        )
        .toList();

    expect(events.whereType<BridgeRunStarted>(), isNotEmpty);
    expect(
      events.whereType<BridgeRunFinished>().length +
          events.whereType<BridgeRunError>().length,
      1,
    );

    await session.dispose();
  });

  test('ReplSession: error does not kill session', () async {
    final session = ReplSession();
    await session.run('x = 10');

    final errResult = await session.run('1 / 0');
    expect(errResult.isError, isTrue);

    final r = await session.run('x');
    expect(r.value, const MontyInt(10));
    await session.dispose();
  });

  test('ReplSession: template result stored and reused', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    await session.run(
      "html = tmpl_render(template='<h1>{{ t }}</h1>', context={'t': 'Hi'})",
    );
    final r = await session.run('len(html)');

    expect(r.value, const MontyInt(11));
    await session.dispose();
  });

  test('ReplSession: dispose is idempotent', () async {
    final session = ReplSession();
    await session.run('1 + 1');
    await session.dispose();
    await session.dispose();
  });

  // -----------------------------------------------------------------------
  // SandboxPlugin — real child interpreter execution
  // -----------------------------------------------------------------------

  test('ReplSession: sandbox_spawn + await real execution', () async {
    final tmpl = DinjaTemplatePlugin();
    final session = ReplSession(
      plugins: [
        SandboxPlugin(
          platformFactory: () async => MontyFfi(),
          parentPlugins: [tmpl],
          maxChildren: 4,
        ),
        tmpl,
      ],
    );

    // Spawn child that computes sum(range(100))
    await session.run("h = sandbox_spawn(code='sum(range(100))')");

    // Await — real child interpreter executes
    final r = await session.run('sandbox_await(h)');
    print('sandbox_await: ${r.value}');
    expect(r.isError, isFalse);
    expect(r.value, const MontyInt(4950));

    await session.dispose();
  });

  test('ReplSession: sandbox result feeds into template', () async {
    final tmpl = DinjaTemplatePlugin();
    final session = ReplSession(
      plugins: [
        SandboxPlugin(
          platformFactory: () async => MontyFfi(),
          parentPlugins: [tmpl],
          maxChildren: 4,
        ),
        tmpl,
      ],
    );

    await session.run("h = sandbox_spawn(code='2 ** 16')");
    await session.run('val = sandbox_await(h)');
    final r = await session.run(
      "tmpl_render(template='Power: {{ v }}', context={'v': val})",
    );
    print('sandbox+template: ${r.value}');
    expect(r.value, isA<MontyString>());

    await session.dispose();
  });

  test('ReplSession: sandbox_gather parallel execution', () async {
    final session = ReplSession(
      plugins: [
        SandboxPlugin(
          platformFactory: () async => MontyFfi(),
          maxChildren: 4,
        ),
      ],
    );

    await session.run("h1 = sandbox_spawn(code='10 + 20')");
    await session.run("h2 = sandbox_spawn(code='3 * 7')");
    await session.run("h3 = sandbox_spawn(code='2 ** 8')");
    final r = await session.run('sandbox_gather(handles=[h1, h2, h3])');
    print('gather: ${r.value}');
    expect(r.isError, isFalse);

    await session.dispose();
  });

  test('ReplSession: sandbox error propagation', () async {
    final session = ReplSession(
      plugins: [
        SandboxPlugin(
          platformFactory: () async => MontyFfi(),
          maxChildren: 4,
        ),
      ],
    );

    await session.run("h = sandbox_spawn(code='1/0')");
    final r = await session.run(
      'try:\n    sandbox_await(h)\nexcept Exception as e:\n'
      '    err = str(e)\nerr',
    );
    print('sandbox error: ${r.value}');
    expect(r.value, isA<MontyString>());

    await session.dispose();
  });

  test('ReplSession: grandchild — child spawns child', () async {
    final tmpl = DinjaTemplatePlugin();
    final sandbox = SandboxPlugin(
      platformFactory: () async => MontyFfi(),
      parentPlugins: [tmpl],
      maxChildren: 4,
      childPluginRegistryFactory: (context) async {
        // Give children their own SandboxPlugin (depth+1) + template
        final childTmpl = DinjaTemplatePlugin();
        final childSandbox = SandboxPlugin(
          platformFactory: () async => MontyFfi(),
          parentPlugins: [childTmpl],
          maxChildren: 2,
          currentDepth: 1,
        );
        final reg = PluginRegistry()
          ..register(childSandbox)
          ..register(childTmpl);
        return reg;
      },
    );
    final session = ReplSession(
      plugins: [sandbox, tmpl],
    );

    // Parent spawns child, child spawns grandchild
    // Use triple-quoted string for the child code to avoid escaping
    await session.run(
      'child_code = """gh = sandbox_spawn(code="6 * 7")\n'
      'sandbox_await(gh)"""',
    );
    final r = await session.run('h = sandbox_spawn(code=child_code)');
    print(
      'grandchild spawn: isError=${r.isError}, '
      'value=${r.value}, error=${r.error}',
    );
    expect(r.isError, isFalse);

    final r2 = await session.run(
      'try:\n    result = sandbox_await(h)\n'
      'except Exception as e:\n    result = str(e)\nresult',
    );
    print('grandchild result: ${r2.value}');

    await session.dispose();
  });
}
