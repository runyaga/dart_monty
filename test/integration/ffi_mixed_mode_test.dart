/// Mixed mode experiments: shared vs sandbox transitions, nested patterns,
/// interleaved plugin combinations, and edge cases.
///
/// Each test runs in its own process invocation (one test per `dart test`
/// call) to avoid cross-session contamination.
///
/// Run individually:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_mixed_mode_test.dart --name "G1"
/// ```
@Tags(['integration'])
library;

// Integration test uses print for output and nullable casts for brevity.
// ignore_for_file: avoid_print, cast_nullable_to_non_nullable
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Host function factories (same as matrix test)
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
    description: 'Awaits 200ms',
  ),
  handler: (_) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));

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

HostFunction counterFn() {
  var count = 0;

  return HostFunction(
    schema: const HostFunctionSchema(
      name: 'counter',
      description: 'Increments and returns a counter',
    ),
    handler: (_) async => ++count,
  );
}

HostFunction accumFn() {
  final items = <String>[];

  return HostFunction(
    schema: const HostFunctionSchema(
      name: 'accum',
      description: 'Accumulates items',
      params: [HostParam(name: 'item', type: HostParamType.string)],
    ),
    handler: (args) async {
      items.add(args['item']! as String);

      return items.length;
    },
  );
}

void main() {
  // ========================================================================
  // G. Shared mode — stress tests
  // ========================================================================

  group('G. Shared mode stress', () {
    test('G1. 20 sequential sync execute calls', () async {
      final s = MontyBridgeSession()..register(syncFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 20; i++) {
        final r = await s.execute('sync_fn()');
        expect(r.value.dartValue, 'sync_ok');
      }
      print('  G1: 20/20 sync');
    });

    test(
      'G2. 10 sequential delay execute calls',
      () async {
        final s = MontyBridgeSession()..register(delayFn());
        addTearDown(s.dispose);
        for (var i = 0; i < 10; i++) {
          final r = await s.execute('delay_fn()');
          expect(r.value.dartValue, 'delay_ok');
        }
        print('  G2: 10/10 delay');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'G3. 10 sequential http execute calls',
      () async {
        final s = MontyBridgeSession()..register(httpFn());
        addTearDown(s.dispose);
        var passed = 0;
        for (var i = 0; i < 10; i++) {
          final r = await s.execute('http_fn()');
          if (r.value.dartValue != null) passed++;
        }
        print('  G3: $passed/10 http');
        expect(passed, 10);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('G4. counter host fn persists Dart-side state', () async {
      final s = MontyBridgeSession()..register(counterFn());
      addTearDown(s.dispose);
      for (var i = 1; i <= 5; i++) {
        final r = await s.execute('counter()');
        expect(r.value.dartValue, i);
      }
      print('  G4: counter 1→5');
    });

    test('G5. accum host fn builds up across execute calls', () async {
      final s = MontyBridgeSession()..register(accumFn());
      addTearDown(s.dispose);
      await s.execute('accum("a")');
      await s.execute('accum("b")');
      final r = await s.execute('accum("c")');
      print('  G5: accum count = ${r.value.dartValue}');
      expect(r.value.dartValue, 3);
    });

    test('G6. state accumulation: build list across 10 calls', () async {
      final s = MontyBridgeSession()..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('items = []');
      for (var i = 0; i < 10; i++) {
        await s.execute('items.append(sync_fn() + "_$i")');
      }
      final r = await s.execute('len(items)');
      print('  G6: ${r.value.dartValue} items');
      expect(r.value.dartValue, 10);
    });

    test('G7. error recovery: bad call then good call', () async {
      final s = MontyBridgeSession()..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('x = 42');
      await s.execute('1/0'); // error
      final r = await s.execute('x');
      print('  G7: x = ${r.value.dartValue} (survived error)');
      expect(r.value.dartValue, 42);
    });

    test(
      'G8. error recovery: bad http then good sync',
      () async {
        final s = MontyBridgeSession()
          ..register(syncFn())
          ..register(httpFn());
        addTearDown(s.dispose);
        await s.execute('data = http_fn()');
        await s.execute('1/0'); // error
        final r = await s.execute('len(data)');
        print('  G8: len(data) = ${r.value.dartValue}');
        expect(r.value.dartValue as int, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // H. Plugin combos across multiple execute calls (shared mode)
  // ========================================================================

  group('H. Plugin combos across execute calls', () {
    test('H1. Template across 5 execute calls', () async {
      final s = MontyBridgeSession(plugins: [JinjaTemplatePlugin()]);
      addTearDown(s.dispose);
      await s.execute('name = "World"');
      await s.execute('greeting = tmpl_render("Hi {{n}}", {"n": name})');
      await s.execute('name = "Alice"');
      await s.execute('greeting2 = tmpl_render("Hi {{n}}", {"n": name})');
      final r = await s.execute('[greeting, greeting2]');
      print('  H1: ${r.value.dartValue}');
      expect(r.value.dartValue, ['Hi World', 'Hi Alice']);
    });

    test('H2. MessageBus across execute calls', () async {
      final s = MontyBridgeSession(plugins: [MessageBusPlugin()]);
      addTearDown(s.dispose);
      await s.execute('msg_send("q", "first")');
      await s.execute('msg_send("q", "second")');
      final r1 = await s.execute('msg_recv("q")');
      final r2 = await s.execute('msg_recv("q")');
      print('  H2: ${r1.value.dartValue}, ${r2.value.dartValue}');
      expect(r1.value.dartValue, 'first');
      expect(r2.value.dartValue, 'second');
    });

    test('H3. FS + Template across calls', () async {
      final s = MontyBridgeSession(
        osHandlers: {'Path.': memoryFsHandler()},
        plugins: [JinjaTemplatePlugin()],
      );
      addTearDown(s.dispose);
      await s.execute('''
from pathlib import Path
Path("/data.txt").write_text("hello")
''');
      await s.execute('''
from pathlib import Path
content = Path("/data.txt").read_text()
''');
      final r = await s.execute(
        'tmpl_render("File has: {{c}}", {"c": content})',
      );
      print('  H3: ${r.value.dartValue}');
      expect(r.value.dartValue, 'File has: hello');
    });

    test(
      'H4. HTTP + Template + MsgBus across calls',
      () async {
        final s = MontyBridgeSession(
          plugins: [JinjaTemplatePlugin(), MessageBusPlugin()],
        )..register(httpFn());
        addTearDown(s.dispose);
        await s.execute('data = http_fn()');
        await s.execute(
          'report = tmpl_render("Got {{n}} bytes", {"n": len(data)})',
        );
        await s.execute('msg_send("log", report)');
        final r = await s.execute('msg_recv("log")');
        print('  H4: ${r.value.dartValue}');
        expect(r.value.dartValue as String, startsWith('Got '));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'H5. HTTP + counter across calls',
      () async {
        final s = MontyBridgeSession()
          ..register(httpFn())
          ..register(counterFn());
        addTearDown(s.dispose);
        await s.execute('http_fn()');
        await s.execute('c1 = counter()');
        await s.execute('http_fn()');
        await s.execute('c2 = counter()');
        final r = await s.execute('[c1, c2]');
        print('  H5: ${r.value.dartValue}');
        expect(r.value.dartValue, [1, 2]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'H6. FS + HTTP + KV across calls',
      () async {
        final kv = <String, String>{};
        final s =
            MontyBridgeSession(
                osHandlers: {'Path.': memoryFsHandler()},
              )
              ..register(httpFn())
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

                    return 'ok';
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
        addTearDown(s.dispose);

        await s.execute('data = http_fn()');
        await s.execute('''
from pathlib import Path
Path("/cache.txt").write_text(data)
''');
        await s.execute('kv_set("cached", "true")');
        await s.execute('''
from pathlib import Path
cached = Path("/cache.txt").read_text()
''');
        final r = await s.execute('[kv_get("cached"), len(cached)]');
        print('  H6: ${r.value.dartValue}');
        final list = r.value.dartValue as List;
        expect(list[0], 'true');
        expect(list[1] as int, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // I. Edge cases
  // ========================================================================

  group('I. Edge cases', () {
    test('I1. empty execute', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('pass');
      print('  I1: ${r.value.dartValue} (None)');
    });

    test('I2. execute with only comments', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('# just a comment');
      print('  I2: ${r.value.dartValue}');
    });

    test('I3. large string return', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('"x" * 100000');
      final v = r.value.dartValue as String;
      print('  I3: ${v.length} chars');
      expect(v.length, 100000);
    });

    test('I4. large list return', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('list(range(1000))');
      final v = r.value.dartValue as List;
      print('  I4: ${v.length} items');
      expect(v.length, 1000);
    });

    test('I5. nested dict return', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('{"a": {"b": {"c": 42}}}');
      final v = r.value.dartValue as Map;
      print('  I5: $v');
      expect((v['a'] as Map)['b'], {'c': 42});
    });

    test('I6. host fn returning None', () async {
      final s = MontyBridgeSession()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'returns_none',
              description: 'Returns null',
            ),
            handler: (_) async => null,
          ),
        );
      addTearDown(s.dispose);
      final r = await s.execute('''
x = returns_none()
x is None
''');
      print('  I6: ${r.value.dartValue}');
      expect(r.value.dartValue, true);
    });

    test('I7. host fn returning large string', () async {
      final s = MontyBridgeSession()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'big_string',
              description: 'Returns 50KB string',
            ),
            handler: (_) async => 'x' * 50000,
          ),
        );
      addTearDown(s.dispose);
      final r = await s.execute('len(big_string())');
      print('  I7: ${r.value.dartValue}');
      expect(r.value.dartValue, 50000);
    });

    test('I8. host fn exception propagates to Python', () async {
      final s = MontyBridgeSession()
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'throws',
              description: 'Throws',
            ),
            handler: (_) async => throw Exception('boom'),
          ),
        );
      addTearDown(s.dispose);
      final r = await s.execute('''
try:
    throws()
    result = "no error"
except Exception as e:
    result = "caught"
result
''');
      print('  I8: ${r.value.dartValue}');
      expect(r.value.dartValue, 'caught');
    });

    test('I9. print output captured', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r = await s.execute('print("hello from monty")');
      print('  I9: printOutput = "${r.printOutput}"');
      expect(r.printOutput, contains('hello from monty'));
    });

    test('I10. multiple prints across execute calls', () async {
      final s = MontyBridgeSession();
      addTearDown(s.dispose);
      final r1 = await s.execute('print("line1")');
      final r2 = await s.execute('print("line2")');
      print('  I10: "${r1.printOutput}" / "${r2.printOutput}"');
      expect(r1.printOutput, contains('line1'));
      expect(r2.printOutput, contains('line2'));
    });
  });
}
