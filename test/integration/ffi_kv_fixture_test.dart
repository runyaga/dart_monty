@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_worker.dart';
import 'kv_stub_functions.dart';
import 'template_stub_extension.dart';

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  for (final storedResult in ['stored', 'ok']) {
    test('typed KV + FS + template with fake HTTP ($storedResult)', () async {
      const body = '{"source":"local fake","value":42}';
      final kv = <String, String>{};
      final session = await MontyRuntime.start(
        pool: pool,
        osHandlers: {'Path.': OSAccess().call},
        extensions: [TemplateStubExtension()],
      );
      addTearDown(session.dispose);
      kvStubFunctions(kv, storedResult: storedResult).forEach(session.register);
      session.register(
        HostFunction(
          schema: const HostFunctionSchema(name: 'http_fn'),
          handler: (_, _) async => const MontyString(body),
        ),
      );

      // Matrix A5/C2: both literal and host-returned strings reach KV handlers.
      expect(
        (await session.execute('kv_set("name", "alice")').result).dartValue,
        storedResult,
      );
      expect(
        (await session.execute('kv_get("name")').result).dartValue,
        'alice',
      );
      expect(
        (await session.execute('''
kv_set("url_data", http_fn())
kv_get("url_data")
''').result).dartValue,
        body,
      );

      // H6: persist fake HTTP data through FS and KV across execute calls.
      await session.execute('data = http_fn()').result;
      await session.execute('''
from pathlib import Path
Path("/cache.txt").write_text(data)
''').result;
      await session.execute('kv_set("cached", "true")').result;
      await session.execute('cached = Path("/cache.txt").read_text()').result;
      expect(
        (await session
                .execute('[kv_get("cached"), cached, len(cached)]')
                .result)
            .dartValue,
        ['true', body, body.length],
      );

      // Matrix E3: a dict with an integer payload passes through the template.
      expect(
        (await session.execute('''
rendered = tmpl_render("Saved {{ n }}", {"n": len(cached)})
kv_set("log", rendered)
kv_get("log")
''').result).dartValue,
        'Saved ${body.length}',
      );
      expect(kv, {
        'name': 'alice',
        'url_data': body,
        'cached': 'true',
        'log': 'Saved ${body.length}',
      });
      expect(
        await session.execute('kv_get("missing")').result,
        const MontyNone(),
      );
    });
  }
}
