/// Systematic FFI plugin combination experiments for #271.
///
/// Tests every combination of host function type × call count × mode
/// to document exactly what works and what crashes.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_plugin_matrix_test.dart --reporter expanded
/// ```
@Tags(['integration'])
library;

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Host function factories
// ---------------------------------------------------------------------------

HostFunction syncFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'sync_fn',
    description: 'Returns immediately',
  ),
  handler: (_) async => 'sync_ok',
);

HostFunction delayFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'delay_fn',
    description: 'Awaits 100ms',
  ),
  handler: (_) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));

    return 'delay_ok';
  },
);

HostFunction httpFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'http_fn',
    description: 'Real HTTP GET',
  ),
  handler: (_) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse(
          'https://demo.toughserv.com/api/v1/installation/versions',
        ),
      );
      final resp = await req.close();
      final body = await resp.transform(const SystemEncoding().decoder).join();

      return body.substring(0, 30);
    } finally {
      client.close();
    }
  },
);

HostFunction kvFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'kv_set',
    description: 'Stores a value',
    params: [
      HostParam(name: 'key', type: HostParamType.string),
      HostParam(name: 'val', type: HostParamType.string),
    ],
  ),
  handler: (args) async {
    _kvStore[args['key']! as String] = args['val']! as String;

    return 'stored';
  },
);

HostFunction kvGetFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'kv_get',
    description: 'Gets a value',
    params: [
      HostParam(name: 'key', type: HostParamType.string),
    ],
  ),
  handler: (args) async => _kvStore[args['key']! as String],
);

final Map<String, String> _kvStore = {};

// ---------------------------------------------------------------------------
// Experiment groups
// ---------------------------------------------------------------------------

void main() {
  setUp(() => _kvStore.clear());

  // ========================================================================
  // A. Single execute() — how many host function calls can we make in one?
  // ========================================================================

  group('A. Single execute(), N host calls inside', () {
    test('A1. sync × 10 in loop', () async {
      final s = AgentSession()..register(syncFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
results = [sync_fn() for _ in range(10)]
len(results)
''');
      print('  A1: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 10);
    });

    test('A2. delay × 5 in loop', () async {
      final s = AgentSession()..register(delayFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
results = [delay_fn() for _ in range(5)]
len(results)
''');
      print('  A2: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 5);
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('A3. http × 3 in loop', () async {
      final s = AgentSession()..register(httpFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
results = [http_fn() for _ in range(3)]
len(results)
''');
      print('  A3: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 3);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      'A4. mixed sync + delay + http in one execute',
      () async {
        final s = AgentSession()
          ..register(syncFn())
          ..register(delayFn())
          ..register(httpFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
r1 = sync_fn()
r2 = delay_fn()
r3 = http_fn()
[r1, r2, len(r3)]
''');
        print('  A4: ${r.value?.dartValue}');
        expect(r.value?.dartValue, isA<List>());
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('A5. kv_set + kv_get in one execute', () async {
      final s = AgentSession()
        ..register(kvFn())
        ..register(kvGetFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
kv_set("name", "alice")
kv_get("name")
''');
      print('  A5: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'alice');
    });
  });

  // ========================================================================
  // B. Multiple execute() calls — shared mode (one interpreter)
  // ========================================================================

  group('B. Multiple execute(), shared mode', () {
    test('B1. sync × 5 execute calls', () async {
      final s = AgentSession()..register(syncFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 5; i++) {
        final r = await s.execute('sync_fn()');
        expect(r.value?.dartValue, 'sync_ok');
      }
      print('  B1: 5/5 sync calls passed');
    });

    test('B2. delay × 5 execute calls', () async {
      final s = AgentSession()..register(delayFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 5; i++) {
        final r = await s.execute('delay_fn()');
        expect(r.value?.dartValue, 'delay_ok');
      }
      print('  B2: 5/5 delay calls passed');
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('B3. http × 5 execute calls', () async {
      final s = AgentSession()..register(httpFn());
      addTearDown(s.dispose);
      var passed = 0;
      for (var i = 0; i < 5; i++) {
        final r = await s.execute('http_fn()');
        if (r.value?.dartValue != null) passed++;
      }
      print('  B3: $passed/5 http calls passed');
      expect(passed, greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('B4. state persists: sync', () async {
      final s = AgentSession()..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('x = sync_fn()');
      final r = await s.execute('x');
      print('  B4: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'sync_ok');
    });

    test('B5. state persists: http', () async {
      final s = AgentSession()..register(httpFn());
      addTearDown(s.dispose);
      await s.execute('data = http_fn()');
      final r = await s.execute('len(data)');
      print('  B5: ${r.value?.dartValue}');
      expect(r.value?.dartValue, greaterThan(0));
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('B6. alternating sync + http', () async {
      final s = AgentSession()
        ..register(syncFn())
        ..register(httpFn());
      addTearDown(s.dispose);
      var passed = 0;
      for (var i = 0; i < 6; i++) {
        final fn = i.isEven ? 'sync_fn()' : 'http_fn()';
        final r = await s.execute(fn);
        if (r.value?.dartValue != null) passed++;
      }
      print('  B6: $passed/6 alternating calls');
      expect(passed, greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // ========================================================================
  // C. Multiple execute() calls — sandbox mode (fresh interpreter each)
  // ========================================================================

  group('C. Multiple execute(), sandbox mode', () {
    test('C1. sync × 10 execute calls', () async {
      final s = AgentSession(sandbox: true)..register(syncFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 10; i++) {
        final r = await s.execute('sync_fn()');
        expect(r.value?.dartValue, 'sync_ok');
      }
      print('  C1: 10/10 sync calls passed');
    });

    test('C2. delay × 5 execute calls', () async {
      final s = AgentSession(sandbox: true)..register(delayFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 5; i++) {
        final r = await s.execute('delay_fn()');
        expect(r.value?.dartValue, 'delay_ok');
      }
      print('  C2: 5/5 delay calls passed');
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('C3. http × 5 execute calls', () async {
      final s = AgentSession(sandbox: true)..register(httpFn());
      addTearDown(s.dispose);
      var passed = 0;
      for (var i = 0; i < 5; i++) {
        final r = await s.execute('http_fn()');
        if (r.value?.dartValue != null) passed++;
      }
      print('  C3: $passed/5 http calls passed');
      expect(passed, greaterThanOrEqualTo(1));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('C4. state persists across sandbox executes', () async {
      final s = AgentSession(sandbox: true)..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('x = sync_fn()');
      final r = await s.execute('x');
      print('  C4: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'sync_ok');
    });

    test('C5. state persists with http', () async {
      final s = AgentSession(sandbox: true)..register(httpFn());
      addTearDown(s.dispose);
      await s.execute('data = http_fn()');
      final r = await s.execute('len(data)');
      print('  C5: ${r.value?.dartValue}');
      if (r.value?.dartValue != null) {
        expect(r.value?.dartValue as int, greaterThan(0));
      }
    }, timeout: const Timeout(Duration(seconds: 15)));

    test('C6. mixed plugins sandbox: template + sync', () async {
      final s = AgentSession(
        sandbox: true,
        plugins: [DinjaTemplatePlugin()],
      )..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('v = sync_fn()');
      final r = await s.execute(
        'tmpl_render("Got: {{ v }}", {"v": v})',
      );
      print('  C6: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'Got: sync_ok');
    });

    test('C7. sandbox 10 sequential sync execute calls', () async {
      final s = AgentSession(sandbox: true)..register(syncFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 10; i++) {
        await s.execute('x_$i = $i');
      }
      final r = await s.execute(
        '[${List.generate(10, (i) => 'x_$i').join(', ')}]',
      );
      print('  C7: ${r.value?.dartValue}');
      expect(r.value?.dartValue, List.generate(10, (i) => i));
    });
  });

  // ========================================================================
  // D. Plugin combinations — all registered, various call patterns
  // ========================================================================

  group('D. Multiple plugins registered', () {
    test('D1. sync + kv + delay in one execute', () async {
      final s = AgentSession()
        ..register(syncFn())
        ..register(kvFn())
        ..register(kvGetFn())
        ..register(delayFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
a = sync_fn()
kv_set("key1", "val1")
b = kv_get("key1")
c = delay_fn()
[a, b, c]
''');
      print('  D1: ${r.value?.dartValue}');
      expect(r.value?.dartValue, ['sync_ok', 'val1', 'delay_ok']);
    });

    test(
      'D2. sync + kv + http in one execute',
      () async {
        final s = AgentSession()
          ..register(syncFn())
          ..register(kvFn())
          ..register(kvGetFn())
          ..register(httpFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
a = sync_fn()
kv_set("url_data", http_fn())
b = kv_get("url_data")
[a, len(b)]
''');
        print('  D2: ${r.value?.dartValue}');
        expect(r.value?.dartValue, isA<List>());
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'D3. all five fns in one execute',
      () async {
        final s = AgentSession()
          ..register(syncFn())
          ..register(delayFn())
          ..register(httpFn())
          ..register(kvFn())
          ..register(kvGetFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
r1 = sync_fn()
r2 = delay_fn()
r3 = http_fn()
kv_set("all", r1 + "_" + r2)
r4 = kv_get("all")
[r1, r2, len(r3), r4]
''');
        print('  D3: ${r.value?.dartValue}');
        final list = r.value?.dartValue as List;
        expect(list[0], 'sync_ok');
        expect(list[1], 'delay_ok');
        expect(list[2] as int, greaterThan(0));
        expect(list[3], 'sync_ok_delay_ok');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'D4. all fns across 3 execute calls (shared mode)',
      () async {
        final s = AgentSession()
          ..register(syncFn())
          ..register(delayFn())
          ..register(httpFn())
          ..register(kvFn())
          ..register(kvGetFn());
        addTearDown(s.dispose);

        await s.execute('a = sync_fn()');
        await s.execute('b = delay_fn()');
        final r = await s.execute('[a, b]');
        print('  D4: ${r.value?.dartValue}');
        expect(r.value?.dartValue, ['sync_ok', 'delay_ok']);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // E. MontyPlugin (TemplatePlugin, MessageBusPlugin)
  // ========================================================================

  group('E. Built-in MontyPlugins', () {
    test('E1. TemplatePlugin in one execute', () async {
      final s = AgentSession(plugins: [DinjaTemplatePlugin()]);
      addTearDown(s.dispose);
      final r = await s.execute('''
tmpl_render("Hello {{ name }}!", {"name": "World"})
''');
      print('  E1: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'Hello World!');
    });

    test('E2. TemplatePlugin across 3 execute calls', () async {
      final s = AgentSession(plugins: [DinjaTemplatePlugin()]);
      addTearDown(s.dispose);
      await s.execute('name = "Alice"');
      await s.execute('greeting = tmpl_render("Hi {{ n }}!", {"n": name})');
      final r = await s.execute('greeting');
      print('  E2: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'Hi Alice!');
    });

    test('E3. MessageBusPlugin send/recv', () async {
      final s = AgentSession(plugins: [MessageBusPlugin()]);
      addTearDown(s.dispose);
      final r = await s.execute('''
msg_send("ch1", "hello")
msg_send("ch1", "world")
r1 = msg_recv("ch1")
r2 = msg_recv("ch1")
[r1, r2]
''');
      print('  E3: ${r.value?.dartValue}');
      expect(r.value?.dartValue, ['hello', 'world']);
    });

    test('E4. Template + MessageBus + sync host fn', () async {
      final s = AgentSession(
        plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
      )..register(syncFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
a = sync_fn()
b = tmpl_render("Result: {{ v }}", {"v": a})
msg_send("results", b)
msg_recv("results")
''');
      print('  E4: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'Result: sync_ok');
    });

    test(
      'E5. Template + MessageBus + HTTP',
      () async {
        final s = AgentSession(
          plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
        )..register(httpFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
data = http_fn()
rendered = tmpl_render("Got {{ n }} bytes", {"n": len(data)})
msg_send("log", rendered)
msg_recv("log")
''');
        print('  E5: ${r.value?.dartValue}');
        expect(r.value?.dartValue, startsWith('Got '));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'E6. All plugins + all host fns in one execute',
      () async {
        final s =
            AgentSession(
                plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
              )
              ..register(syncFn())
              ..register(delayFn())
              ..register(httpFn())
              ..register(kvFn())
              ..register(kvGetFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
# All host functions
a = sync_fn()
b = delay_fn()
c = http_fn()
kv_set("combo", a)
d = kv_get("combo")

# Template
e = tmpl_render("{{ a }}-{{ b }}", {"a": a, "b": b})

# Message bus
msg_send("ch", e)
f = msg_recv("ch")

[a, b, len(c), d, e, f]
''');
        print('  E6: ${r.value?.dartValue}');
        final list = r.value?.dartValue as List;
        expect(list[0], 'sync_ok');
        expect(list[1], 'delay_ok');
        expect(list[4], 'sync_ok-delay_ok');
        expect(list[5], 'sync_ok-delay_ok');
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // F. Filesystem + host functions
  // ========================================================================

  group('F. Filesystem + host functions', () {
    test('F1. write file + sync fn', () async {
      final s = AgentSession(
        os: OsProvider.compose({
          'Path.': MemoryFsProvider(),
        }),
      )..register(syncFn());
      addTearDown(s.dispose);
      final r = await s.execute('''
from pathlib import Path
data = sync_fn()
Path("/out.txt").write_text(data)
Path("/out.txt").read_text()
''');
      print('  F1: ${r.value?.dartValue}');
      expect(r.value?.dartValue, 'sync_ok');
    });

    test(
      'F2. http → write file → read file',
      () async {
        final s = AgentSession(
          os: OsProvider.compose({
            'Path.': MemoryFsProvider(),
          }),
        )..register(httpFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
from pathlib import Path
data = http_fn()
Path("/data.json").write_text(data)
len(Path("/data.json").read_text())
''');
        print('  F2: ${r.value?.dartValue}');
        expect(r.value?.dartValue as int, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'F3. fs + template + message bus + http',
      () async {
        final s = AgentSession(
          os: OsProvider.compose({
            'Path.': MemoryFsProvider(),
          }),
          plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
        )..register(httpFn());
        addTearDown(s.dispose);
        final r = await s.execute('''
from pathlib import Path
data = http_fn()
Path("/raw.txt").write_text(data)
rendered = tmpl_render("Saved {{ n }} bytes", {"n": len(data)})
msg_send("log", rendered)
log = msg_recv("log")
saved = Path("/raw.txt").read_text()
[log, len(saved)]
''');
        print('  F3: ${r.value?.dartValue}');
        final list = r.value?.dartValue as List;
        expect((list[0] as String), startsWith('Saved '));
        expect(list[1] as int, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });
}
