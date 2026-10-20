/// Mixed mode experiments: shared vs sandbox transitions, nested patterns,
/// interleaved plugin combinations, and edge cases.
///
/// Each test runs in its own process invocation (one test per `dart test`
/// call) to avoid cross-session contamination.
///
/// Run individually:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_mixed_mode_test.dart --name "20 sequential sync execute calls"
/// ```
@Tags(['integration'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
// Integration test uses print for output and nullable casts for brevity.
// ignore_for_file: avoid_print
import 'package:test/test.dart';

import '_printed.dart';
import '_worker.dart';
import 'kv_stub_functions.dart';
import 'template_stub_extension.dart';

// ---------------------------------------------------------------------------
// Host function factories (same as matrix test)
// ---------------------------------------------------------------------------

HostFunction syncFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'sync_fn',
    description: 'Returns immediately',
  ),
  handler: (_, ctx) async => const MontyString('sync_ok'),
);

HostFunction delayFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'delay_fn',
    description: 'Awaits 200ms',
  ),
  handler: (_, _) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));

    return const MontyString('delay_ok');
  },
);

HostFunction httpFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'http_fn',
    description: 'Real HTTP GET',
  ),
  handler: (_, _) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(
        Uri.parse(
          'https://demo.toughserv.com/api/v1/installation/versions',
        ),
      );
      final resp = await req.close();
      final body = await resp.transform(const SystemEncoding().decoder).join();

      return MontyValue.fromDart(body.substring(0, 30));
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
    handler: (_, _) async => MontyValue.fromDart(++count),
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
    handler: (args, _) async {
      items.add((args['item']! as MontyString).value);

      return MontyValue.fromDart(items.length);
    },
  );
}

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  // ========================================================================
  // G. Shared mode — stress tests
  // ========================================================================

  group('G. Shared mode stress', () {
    test('20 sequential sync execute calls', () async {
      final s = (await MontyRuntime.start(pool: pool))..register(syncFn());
      addTearDown(s.dispose);
      for (var i = 0; i < 20; i++) {
        final r = await s.execute('sync_fn()').result;
        expect(r.dartValue, 'sync_ok');
      }
      print('  G1: 20/20 sync');
    });

    test(
      '10 sequential delay execute calls',
      () async {
        final s = (await MontyRuntime.start(pool: pool))..register(delayFn());
        addTearDown(s.dispose);
        for (var i = 0; i < 10; i++) {
          final r = await s.execute('delay_fn()').result;
          expect(r.dartValue, 'delay_ok');
        }
        print('  G2: 10/10 delay');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      '10 sequential http execute calls',
      () async {
        final s = (await MontyRuntime.start(pool: pool))..register(httpFn());
        addTearDown(s.dispose);
        var passed = 0;
        for (var i = 0; i < 10; i++) {
          final r = await s.execute('http_fn()').result;
          if (r.dartValue != null) passed++;
        }
        print('  G3: $passed/10 http');
        expect(passed, 10);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test('counter host function persists Dart-side state', () async {
      final s = (await MontyRuntime.start(pool: pool))..register(counterFn());
      addTearDown(s.dispose);
      for (var i = 1; i <= 5; i++) {
        final r = await s.execute('counter()').result;
        expect(r.dartValue, i);
      }
      print('  G4: counter 1→5');
    });

    test('accum host function builds up across execute calls', () async {
      final s = (await MontyRuntime.start(pool: pool))..register(accumFn());
      addTearDown(s.dispose);
      await s.execute('accum("a")').result;
      await s.execute('accum("b")').result;
      final r = await s.execute('accum("c")').result;
      print('  G5: accum count = ${r.dartValue}');
      expect(r.dartValue, 3);
    });

    test('state accumulates in a list across 10 calls', () async {
      final s = (await MontyRuntime.start(pool: pool))..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('items = []').result;
      for (var i = 0; i < 10; i++) {
        await s.execute('items.append(sync_fn() + "_$i")').result;
      }
      final r = await s.execute('len(items)').result;
      print('  G6: ${r.dartValue} items');
      expect(r.dartValue, 10);
    });

    test('a bad call does not prevent a good call', () async {
      final s = (await MontyRuntime.start(pool: pool))..register(syncFn());
      addTearDown(s.dispose);
      await s.execute('x = 42').result;
      // Raises.
      await expectLater(
        s.execute('1/0').result,
        throwsA(isA<MontyError>()),
      );
      final r = await s.execute('x').result;
      print('  G7: x = ${r.dartValue} (survived error)');
      expect(r.dartValue, 42);
    });

    test(
      'a bad HTTP call does not prevent a good sync call',
      () async {
        final s = (await MontyRuntime.start(pool: pool))
          ..register(syncFn())
          ..register(httpFn());
        addTearDown(s.dispose);
        await s.execute('data = http_fn()').result;
        // Raises.
        await expectLater(
          s.execute('1/0').result,
          throwsA(isA<MontyError>()),
        );
        final r = await s.execute('len(data)').result;
        print('  G8: len(data) = ${r.dartValue}');
        expect(r.dartValue! as int, greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // H. Plugin combos across multiple execute calls (shared mode)
  // ========================================================================

  group('H. Plugin combos across execute calls', () {
    test('H1. Template across 5 execute calls', () async {
      final s = await MontyRuntime.start(
        pool: pool,
        extensions: [TemplateStubExtension()],
      );
      addTearDown(s.dispose);
      await s.execute('name = "World"').result;
      await s.execute('greeting = tmpl_render("Hi {{n}}", {"n": name})').result;
      await s.execute('name = "Alice"').result;
      await s
          .execute('greeting2 = tmpl_render("Hi {{n}}", {"n": name})')
          .result;
      final r = await s.execute('[greeting, greeting2]').result;
      print('  H1: ${r.dartValue}');
      expect(r.dartValue, ['Hi World', 'Hi Alice']);
    });

    test('H3. FS + Template across calls', () async {
      final s = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
        extensions: [TemplateStubExtension()],
      );
      addTearDown(s.dispose);
      await s.execute('''
from pathlib import Path
Path("/data.txt").write_text("hello")
''').result;
      await s.execute('''
from pathlib import Path
content = Path("/data.txt").read_text()
''').result;
      final r = await s
          .execute(
            'tmpl_render("File has: {{c}}", {"c": content})',
          )
          .result;
      print('  H3: ${r.dartValue}');
      expect(r.dartValue, 'File has: hello');
    });

    test(
      'H4. HTTP + Template across calls',
      () async {
        final s = (await MontyRuntime.start(
          pool: pool,
          extensions: [TemplateStubExtension()],
        ))..register(httpFn());
        addTearDown(s.dispose);
        await s.execute('data = http_fn()').result;
        await s
            .execute(
              'report = tmpl_render("Got {{n}} bytes", {"n": len(data)})',
            )
            .result;
        final r = await s.execute('report').result;
        print('  H4: ${r.dartValue}');
        expect(r.dartValue! as String, startsWith('Got '));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'H5. HTTP + counter across calls',
      () async {
        final s = (await MontyRuntime.start(pool: pool))
          ..register(httpFn())
          ..register(counterFn());
        addTearDown(s.dispose);
        final firstHttp = s.execute('http_fn()');
        await firstHttp.result;
        await s.execute('c1 = counter()').result;
        final secondHttp = s.execute('http_fn()');
        await secondHttp.result;
        await s.execute('c2 = counter()').result;
        final r = await s.execute('[c1, c2]').result;
        print('  H5: ${r.dartValue}');
        expect(r.dartValue, [1, 2]);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'H6. FS + HTTP + KV across calls',
      () async {
        final kv = <String, String>{};
        final s = (await MontyRuntime.start(
          pool: pool,
          osHandlers: {'Path.': OSAccess().call},
        ))..register(httpFn());
        kvStubFunctions(kv, storedResult: 'ok').forEach(s.register);
        addTearDown(s.dispose);

        await s.execute('data = http_fn()').result;
        await s.execute('''
from pathlib import Path
Path("/cache.txt").write_text(data)
''').result;
        await s.execute('kv_set("cached", "true")').result;
        await s.execute('''
from pathlib import Path
cached = Path("/cache.txt").read_text()
''').result;
        final r = await s.execute('[kv_get("cached"), len(cached)]').result;
        print('  H6: ${r.dartValue}');
        final list = r.dartValue! as List;
        expect(list.first, 'true');
        expect(list[1], greaterThan(0));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );
  });

  // ========================================================================
  // I. Edge cases
  // ========================================================================

  group('I. Edge cases', () {
    test('I1. empty execute', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final r = await s.execute('pass').result;
      print('  I1: ${r.dartValue} (None)');
    });

    test('I2. execute with only comments', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final r = await s.execute('# just a comment').result;
      print('  I2: ${r.dartValue}');
    });

    test('I3. large string return', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final r = await s.execute('"x" * 100000').result;
      final v = r.dartValue! as String;
      print('  I3: ${v.length} chars');
      expect(v.length, 100000);
    });

    test('I4. large list return', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final r = await s.execute('list(range(1000))').result;
      final v = r.dartValue! as List;
      print('  I4: ${v.length} items');
      expect(v.length, 1000);
    });

    test('I5. nested dict return', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final r = await s.execute('{"a": {"b": {"c": 42}}}').result;
      final v = r.dartValue! as Map;
      print('  I5: $v');
      expect((v['a'] as Map)['b'], {'c': 42});
    });

    test('I6. host fn returning None', () async {
      final s = (await MontyRuntime.start(pool: pool))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'returns_none',
              description: 'Returns null',
            ),
            handler: (_, _) async => const MontyNone(),
          ),
        );
      addTearDown(s.dispose);
      final r = await s.execute('''
x = returns_none()
x is None
''').result;
      print('  I6: ${r.dartValue}');
      expect(r.dartValue, true);
    });

    test('I7. host fn returning large string', () async {
      final s = (await MontyRuntime.start(pool: pool))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'big_string',
              description: 'Returns 50KB string',
            ),
            handler: (_, _) async => MontyValue.fromDart('x' * 50000),
          ),
        );
      addTearDown(s.dispose);
      final r = await s.execute('len(big_string())').result;
      print('  I7: ${r.dartValue}');
      expect(r.dartValue, 50000);
    });

    test('I8. host fn exception propagates to Python', () async {
      final s = (await MontyRuntime.start(pool: pool))
        ..register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'throws',
              description: 'Throws',
            ),
            handler: (_, _) async => throw Exception('boom'),
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
''').result;
      print('  I8: ${r.dartValue}');
      expect(r.dartValue, 'caught');
    });

    test('I9. print output captured', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final out = await printedBy(s.execute('print("hello from monty")'));
      print('  I9: printOutput = "$out"');
      expect(out, contains('hello from monty'));
    });

    test('I10. multiple prints across execute calls', () async {
      final s = await MontyRuntime.start(pool: pool);
      addTearDown(s.dispose);
      final out1 = await printedBy(s.execute('print("line1")'));
      final out2 = await printedBy(s.execute('print("line2")'));
      print('  I10: "$out1" / "$out2"');
      expect(out1, contains('line1'));
      expect(out2, contains('line2'));
    });
  });
}
