// Experiment: Python-driven tool call chains without a server.
//
// Demonstrates the harness exercising a multi-step tool call chain —
// exactly what an LLM would produce, but driven by hand-written Python.
// No server, no LLM, no network.
//
// Run with:
//   dart test --tags=integration --run-skipped \
//     test/experiment/examples/tool_chain_experiment_test.dart
@Tags(['integration'])
library;

import 'dart:convert';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Basic tool call: single function, verify args and result round-trip
  // ---------------------------------------------------------------------------

  group('single tool call', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'get_weather',
          (args, ctx) async => {'temp': 22, 'city': args['city'], 'unit': 'C'},
          description: 'Returns weather for a city',
          params: [const HostParam(name: 'city', type: HostParamType.string)],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python calls get_weather and uses the result', () async {
      final result = await h.run('''
w = get_weather(city='London')
w['temp']
''');

      expect(result.error, isNull);
      expect(result.value.dartValue, 22);
      h.assertCalled('get_weather', args: {'city': 'London'});
    });

    test('Python error does not block subsequent calls', () async {
      final r1 = await h.run('undefined_var');
      expect(r1.error, isNotNull);

      final r2 = await h.run("get_weather(city='Paris')['temp']");
      expect(r2.error, isNull);
      expect(r2.value.dartValue, 22);
    });

    test('tool called multiple times — all recorded', () async {
      await h.run('''
cities = ['London', 'Paris', 'Berlin']
results = [get_weather(city=c)['temp'] for c in cities]
''');

      h
        ..assertCallCount('get_weather', 3)
        ..assertCalled('get_weather', args: {'city': 'London'})
        ..assertCalled('get_weather', args: {'city': 'Paris'})
        ..assertCalled('get_weather', args: {'city': 'Berlin'});
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-tool chain: Python drives a decision flow across tools
  // ---------------------------------------------------------------------------

  group('multi-tool chain', () {
    late MontyHarness h;

    setUp(() async {
      final db = <String, Map<String, Object?>>{
        'user:alice': {'name': 'Alice', 'tier': 'premium', 'balance': 150},
        'user:bob': {'name': 'Bob', 'tier': 'free', 'balance': 0},
      };
      final log = <String>[];

      h = MontyHarness()
        ..registerTool(
          'db_get',
          (args, ctx) async =>
              db[args['key']! as String] ?? <String, Object?>{},
          params: [const HostParam(name: 'key', type: HostParamType.string)],
        )
        ..registerTool(
          'send_offer',
          (args, ctx) async {
            log.add('offer:${args['user']}:${args['offer']}');
            return true;
          },
          params: [
            const HostParam(name: 'user', type: HostParamType.string),
            const HostParam(name: 'offer', type: HostParamType.string),
          ],
        )
        ..registerTool(
          'send_upsell',
          (args, ctx) async {
            log.add('upsell:${args['user']}');
            return true;
          },
          params: [const HostParam(name: 'user', type: HostParamType.string)],
        );

      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python routes to correct tool based on user tier', () async {
      await h.run('''
alice = db_get(key='user:alice')
if alice['tier'] == 'premium':
    send_offer(user=alice['name'], offer='20pct_off')
else:
    send_upsell(user=alice['name'])
''');

      h
        ..assertCalled(
          'send_offer',
          args: {'user': 'Alice', 'offer': '20pct_off'},
        )
        ..assertNotCalled('send_upsell');
    });

    test('Python routes free-tier user to upsell', () async {
      await h.run('''
bob = db_get(key='user:bob')
if bob['tier'] == 'premium':
    send_offer(user=bob['name'], offer='20pct_off')
else:
    send_upsell(user=bob['name'])
''');

      h
        ..assertCalled('send_upsell', args: {'user': 'Bob'})
        ..assertNotCalled('send_offer');
    });

    test('Python loops over multiple users', () async {
      await h.run('''
for uid in ['user:alice', 'user:bob']:
    u = db_get(key=uid)
    if u['tier'] == 'premium':
        send_offer(user=u['name'], offer='30pct_off')
    else:
        send_upsell(user=u['name'])
''');

      h
        ..assertCallCount('db_get', 2)
        ..assertCallCount('send_offer', 1)
        ..assertCallCount('send_upsell', 1);
    });
  });

  // ---------------------------------------------------------------------------
  // VFS: Python reads files from the in-memory filesystem
  // ---------------------------------------------------------------------------

  group('VFS-backed tool calls', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..writeFile(
          '/config/rules.json',
          jsonEncode({
            'discount_threshold': 100,
            'premium_offer': '25pct_off',
          }),
        )
        ..registerTool(
          'apply_discount',
          (args, ctx) async => 'discount:${args['offer']}:${args['user']}',
          params: [
            const HostParam(name: 'offer', type: HostParamType.string),
            const HostParam(name: 'user', type: HostParamType.string),
          ],
        )
        ..prime('from pathlib import Path');

      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python reads config from VFS and drives tool call', () async {
      final result = await h.run('''
import json
config = json.loads(Path('/config/rules.json').read_text())
threshold = config['discount_threshold']
balance = 150
if balance >= threshold:
    apply_discount(offer=config['premium_offer'], user='alice')
''');

      expect(result.error, isNull);
      h.assertCalled(
        'apply_discount',
        args: {
          'offer': '25pct_off',
          'user': 'alice',
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Python scripts loaded from VFS — simulating skill files
  // ---------------------------------------------------------------------------

  group('skill script loading', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..writeFile('/scripts/greet.py', '''
def greet_user(name, lang='en'):
    if lang == 'en':
        return f'Hello, {name}!'
    elif lang == 'es':
        return f'Hola, {name}!'
    return f'Hi, {name}!'
''')
        ..registerTool(
          'send_message',
          (args, ctx) async => 'sent:${args['msg']}',
          params: [const HostParam(name: 'msg', type: HostParamType.string)],
        )
        ..prime('from pathlib import Path');

      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python executes a skill script from VFS then calls a tool', () async {
      // Load the skill script by executing it.
      await h.runFile('/scripts/greet.py');

      // Now greet_user is defined in the session — call it and forward result.
      final result = await h.run('''
msg = greet_user('World', lang='es')
send_message(msg=msg)
''');

      expect(result.error, isNull);
      h.assertCalled('send_message', args: {'msg': 'Hola, World!'});
    });
  });

  // ---------------------------------------------------------------------------
  // Event stream inspection
  // ---------------------------------------------------------------------------

  group('bridge event stream', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()..registerTool('probe', (args, ctx) async => 'ok');
      await h.setup();
    });

    tearDown(() => h.dispose());

    test(
      'runWithEvents captures BridgeToolCallStart for each tool call',
      () async {
        final (:result, :events) = await h.runWithEvents('probe()');

        expect(result.error, isNull);
        final starts = events.whereType<BridgeFunctionCallStart>().toList();
        expect(starts.map((e) => e.name), contains('probe'));
      },
    );

    test('runWithEvents captures BridgeRunFinished', () async {
      final (:result, :events) = await h.runWithEvents('1 + 1');

      expect(events.whereType<BridgeRunFinished>(), isNotEmpty);
      expect(result.value.dartValue, 2);
    });
  });
}
