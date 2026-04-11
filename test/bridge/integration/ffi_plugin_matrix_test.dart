/// FFI plugin combination tests — ALL in one test to avoid zone contamination.
///
/// The dart test runner creates zones per test. Zone cleanup between tests
/// corrupts FFI state. Solution: one test, all assertions inside.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_plugin_matrix_test.dart
/// ```
@Tags(['integration'])
library;

// ignore_for_file: avoid_print, cast_nullable_to_non_nullable
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  test(
    'FFI plugin matrix — 30 experiments in one session',
    () async {
      final kv = <String, String>{};
      final session = AgentSession(
        os: OsProvider.compose({
          'Path.': MemoryFsProvider(),
          'date.': TimeOsProvider(),
          'datetime.': TimeOsProvider(),
        }),
        plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
      )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'sync_fn',
              description: 'Returns immediately',
            ),
            handler: (_) async => 'sync_ok',
          ),
        )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'delay_fn',
              description: 'Awaits 200ms',
            ),
            handler: (_) async {
              await Future<void>.delayed(
                const Duration(milliseconds: 200),
              );

              return 'delay_ok';
            },
          ),
        )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'http_fn',
              description: 'Real HTTP GET',
            ),
            handler: (_) async {
              final client = HttpClient();
              try {
                final req = await client.getUrl(
                  Uri.parse(
                    'https://demo.toughserv.com'
                    '/api/v1/installation/versions',
                  ),
                );
                final resp = await req.close();
                final body = await resp
                    .transform(const SystemEncoding().decoder)
                    .join();

                return body.substring(0, 30);
              } finally {
                client.close();
              }
            },
          ),
        )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'kv_set',
              description: 'Set',
              params: [
                HostParam(name: 'k', type: HostParamType.string),
                HostParam(name: 'v', type: HostParamType.string),
              ],
            ),
            handler: (a) async {
              kv[a['k']! as String] = a['v']! as String;

              return 'stored';
            },
          ),
        )
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'kv_get',
              description: 'Get',
              params: [
                HostParam(name: 'k', type: HostParamType.string),
              ],
            ),
            handler: (a) async => kv[a['k']! as String],
          ),
        );

      try {
        // ── A. Single execute, N host calls ──────────────────────────
        var r = await session.execute('''
results = [sync_fn() for _ in range(10)]
len(results)
''');
        expect(r.value?.dartValue, 10);
        print('  A1. sync × 10: PASS');

        r = await session.execute('''
results = [delay_fn() for _ in range(5)]
len(results)
''');
        expect(r.value?.dartValue, 5);
        print('  A2. delay × 5: PASS');

        r = await session.execute('''
results = [http_fn() for _ in range(3)]
len(results)
''');
        expect(r.value?.dartValue, 3);
        print('  A3. http × 3: PASS');

        r = await session.execute('''
r1 = sync_fn()
r2 = delay_fn()
r3 = http_fn()
[r1, r2, len(r3)]
''');
        expect(r.value?.dartValue, isA<List>());
        print('  A4. mixed sync+delay+http: PASS');

        r = await session.execute('''
kv_set("name", "alice")
kv_get("name")
''');
        expect(r.value?.dartValue, 'alice');
        print('  A5. kv_set+kv_get: PASS');

        // ── B. State persistence ─────────────────────────────────────

        await session.execute('x = sync_fn()');
        r = await session.execute('x');
        expect(r.value?.dartValue, 'sync_ok');
        print('  B1. state persists (sync): PASS');

        await session.execute('hdata = http_fn()');
        r = await session.execute('len(hdata)');
        expect(r.value?.dartValue as int, greaterThan(0));
        print('  B2. state persists (http): PASS');

        await session.execute('items = []');
        await session.execute('items.append("a")');
        await session.execute('items.append("b")');
        r = await session.execute('len(items)');
        expect(r.value?.dartValue, 2);
        print('  B3. list accumulation: PASS');

        await session.execute('safe_val = 42');
        await session.execute('1/0');
        r = await session.execute('safe_val');
        expect(r.value?.dartValue, 42);
        print('  B4. error recovery: PASS');

        // ── C. Plugin combinations ───────────────────────────────────

        r = await session.execute('''
a = sync_fn()
kv_set("k1", "v1")
b = kv_get("k1")
c = delay_fn()
[a, b, c]
''');
        expect(r.value?.dartValue, ['sync_ok', 'v1', 'delay_ok']);
        print('  C1. sync+kv+delay: PASS');

        r = await session.execute('''
a = sync_fn()
kv_set("url_data", http_fn())
b = kv_get("url_data")
[a, len(b)]
''');
        expect(r.value?.dartValue, isA<List>());
        print('  C2. sync+kv+http: PASS');

        r = await session.execute('''
r1 = sync_fn()
r2 = delay_fn()
r3 = http_fn()
kv_set("all", r1 + "_" + r2)
r4 = kv_get("all")
[r1, r2, len(r3), r4]
''');
        final c3 = r.value?.dartValue as List;
        expect(c3[0], 'sync_ok');
        expect(c3[3], 'sync_ok_delay_ok');
        print('  C3. all 5 fns: PASS');

        // ── D. Built-in plugins ──────────────────────────────────────

        r = await session.execute(
          'tmpl_render("Hello {{ n }}!", {"n": "World"})',
        );
        expect(r.value?.dartValue, 'Hello World!');
        print('  D1. template: PASS');

        r = await session.execute('''
msg_send("ch1", "hello")
msg_send("ch1", "world")
r1 = msg_recv("ch1")
r2 = msg_recv("ch1")
[r1, r2]
''');
        expect(r.value?.dartValue, ['hello', 'world']);
        print('  D2. msgbus: PASS');

        r = await session.execute('''
a = sync_fn()
b = tmpl_render("R: {{ v }}", {"v": a})
msg_send("res", b)
msg_recv("res")
''');
        expect(r.value?.dartValue, 'R: sync_ok');
        print('  D3. template+msgbus+sync: PASS');

        r = await session.execute('''
data = http_fn()
rendered = tmpl_render("Got {{ n }}", {"n": len(data)})
msg_send("log", rendered)
msg_recv("log")
''');
        expect(r.value?.dartValue as String, startsWith('Got '));
        print('  D4. template+msgbus+http: PASS');

        r = await session.execute('''
a = sync_fn()
b = delay_fn()
c = http_fn()
kv_set("combo", a)
d = kv_get("combo")
e = tmpl_render("{{ a }}-{{ b }}", {"a": a, "b": b})
msg_send("ch", e)
f = msg_recv("ch")
[a, b, len(c), d, e, f]
''');
        final d5 = r.value?.dartValue as List;
        expect(d5[0], 'sync_ok');
        expect(d5[4], 'sync_ok-delay_ok');
        print('  D5. ALL plugins+fns: PASS');

        // ── E. Filesystem ────────────────────────────────────────────

        r = await session.execute('''
from pathlib import Path
Path("/out.txt").write_text(sync_fn())
Path("/out.txt").read_text()
''');
        expect(r.value?.dartValue, 'sync_ok');
        print('  E1. fs write+read: PASS');

        r = await session.execute('''
from pathlib import Path
data = http_fn()
Path("/data.json").write_text(data)
len(Path("/data.json").read_text())
''');
        expect(r.value?.dartValue as int, greaterThan(0));
        print('  E2. http→fs: PASS');

        r = await session.execute('''
from pathlib import Path
data = http_fn()
Path("/raw.txt").write_text(data)
rendered = tmpl_render("Saved {{ n }}", {"n": len(data)})
msg_send("log2", rendered)
log = msg_recv("log2")
saved = Path("/raw.txt").read_text()
[log, len(saved)]
''');
        final e3 = r.value?.dartValue as List;
        expect(e3[0] as String, startsWith('Saved '));
        print('  E3. fs+template+msgbus+http: PASS');

        // ── F. Edge cases ────────────────────────────────────────────

        r = await session.execute('"x" * 100000');
        expect((r.value?.dartValue as String).length, 100000);
        print('  F1. large string (100K): PASS');

        r = await session.execute('list(range(1000))');
        expect((r.value?.dartValue as List).length, 1000);
        print('  F2. large list (1000): PASS');

        r = await session.execute('{"a": {"b": {"c": 42}}}');
        expect(
          ((r.value?.dartValue as Map)['a'] as Map)['b'],
          {'c': 42},
        );
        print('  F3. nested dict: PASS');

        r = await session.execute('print("hello")');
        expect(r.printOutput, contains('hello'));
        print('  F4. print capture: PASS');

        r = await session.execute('''
results = []
for i in range(5):
    results.append(len(http_fn()))
results
''');
        expect((r.value?.dartValue as List).length, 5);
        print('  F5. http × 5 loop: PASS');

        print('\n  ALL 25 EXPERIMENTS PASSED ✅');
      } finally {
        await session.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 300)),
  );
}
