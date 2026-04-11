@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/plugins/template_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/message_bus_plugin.dart';
import 'package:test/test.dart';

void main() {
  test('Multi-turn: 10 sequential execute() calls with tmpl_render', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    for (var i = 0; i < 10; i++) {
      final events = await session
          .execute("tmpl_render(template='Turn {{ n }}', context={'n': $i})")
          .toList();
      expect(
        events.whereType<BridgeRunFinished>(),
        hasLength(1),
        reason: 'Turn $i should complete',
      );
      final finished = events.whereType<BridgeRunFinished>().first;
      expect(finished.value, 'Turn $i');
    }

    await session.dispose();
  });

  test('Multi-turn: state persists across 20 stream executions', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    // Accumulate state across turns
    await session.run('total = 0');
    for (var i = 1; i <= 20; i++) {
      await session.run('total += $i');
    }
    final r = await session.run('total');
    expect(r.value, const MontyInt(210)); // sum 1..20

    await session.dispose();
  });

  test('Multi-turn: template + error + template recovery', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    // Turn 1: successful template
    final r1 = await session.run(
      "tmpl_render(template='Hi {{ x }}', context={'x': 1})",
    );
    expect(r1.value, isA<MontyString>());

    // Turn 2: error (ZeroDivisionError)
    final r2 = await session.run('1 / 0');
    expect(r2.isError, isTrue);

    // Turn 3: template still works after error
    final r3 = await session.run(
      "tmpl_render(template='Recovered {{ v }}', context={'v': 42})",
    );
    expect((r3.value! as MontyString).value, 'Recovered 42');

    await session.dispose();
  });

  test('Multi-turn: interleave template and pure Python', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    await session.run('data = []');
    for (var i = 0; i < 5; i++) {
      await session.run('data.append($i)');
      final r = await session.run(
        "tmpl_render(template='len={{ n }}', context={'n': len(data)})",
      );
      expect((r.value! as MontyString).value, 'len=${i + 1}');
    }

    await session.dispose();
  });

  test('Multi-turn: BridgeEvent stream has tool call events', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    final events = await session
        .execute("tmpl_render(template='test', context={})")
        .toList();

    // Should have: RunStarted, ToolCallStart, ToolCallResult, RunFinished
    expect(events.whereType<BridgeRunStarted>(), isNotEmpty);
    expect(events.whereType<BridgeToolCallStart>(), isNotEmpty);
    expect(events.whereType<BridgeToolCallResult>(), isNotEmpty);
    expect(events.whereType<BridgeRunFinished>(), isNotEmpty);

    await session.dispose();
  });

  test('Multi-turn: 5 rapid stream executions back-to-back', () async {
    final session = ReplSession(plugins: [DinjaTemplatePlugin()]);

    for (var i = 0; i < 5; i++) {
      final events = await session.execute('$i * $i').toList();
      final finished = events.whereType<BridgeRunFinished>().first;
      expect(finished.value, i * i, reason: 'Turn $i: $i*$i');
    }

    await session.dispose();
  });

  test('Multi-turn: MessageBus across turns', () async {
    final session = ReplSession(plugins: [MessageBusPlugin()]);

    await session.run("msg_send('ch', 'hello')");
    await session.run("msg_send('ch', 'world')");
    final r = await session.run("msg_recv('ch')");
    expect(r.value, const MontyString('hello'));
    final r2 = await session.run("msg_recv('ch')");
    expect(r2.value, const MontyString('world'));

    await session.dispose();
  });
}
