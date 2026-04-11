@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/plugins/template_plugin.dart';
import 'package:test/test.dart';

/// Integration tests for [ReplSession] with real plugin dispatch.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/repl/repl_session_test.dart
/// ```
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
    expect((r.value! as MontyString).value, 'Hello World!');
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
    expect((r.value! as MontyString).value, 'avg=87.6, top=95');
    await session.dispose();
  });

  test('ReplSession: tmpl_render with for loop', () async {
    final session = ReplSession(
      plugins: [DinjaTemplatePlugin()],
    );

    await session.run("items = ['Alice', 'Bob']");
    final r = await session.run(
      "tmpl_render("
      "template='{% for u in items %}{{ u }} {% endfor %}', "
      "context={'items': items})",
    );

    expect(r.value, isA<MontyString>());
    expect(
      (r.value! as MontyString).value,
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

    // Should have lifecycle events
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

    expect(r.value, const MontyInt(11)); // <h1>Hi</h1> = 11 chars
    await session.dispose();
  });

  test('ReplSession: dispose is idempotent', () async {
    final session = ReplSession();
    await session.run('1 + 1');
    await session.dispose();
    await session.dispose(); // no-op
  });
}
