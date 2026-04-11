/// Verifies #271 workaround: a SINGLE long-lived AgentSession can make
/// multiple HTTP host function calls without crashing.
///
/// The crash only occurs when multiple sessions are created/disposed in the
/// same process. One persistent session avoids cross-session contamination.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_single_session_http_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  late AgentSession session;

  setUpAll(() {
    session = AgentSession(sandbox: true)
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'http_get',
            description: 'Fetches a URL and returns first N chars',
            params: [
              HostParam(name: 'url', type: HostParamType.string),
            ],
          ),
          handler: (args) async {
            final url = args['url']! as String;
            final client = HttpClient();
            try {
              final request = await client.getUrl(Uri.parse(url));
              final response = await request.close();
              final body = await response
                  .transform(const SystemEncoding().decoder)
                  .join();

              return body.length > 100 ? body.substring(0, 100) : body;
            } finally {
              client.close();
            }
          },
        ),
      );
  });

  tearDownAll(() async {
    await session.dispose();
  });

  test('call 1 — HTTP works', () async {
    final r = await session.execute(
      'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
    );
    expect(r.value?.dartValue, isA<String>());
    expect((r.value!.dartValue! as String).length, greaterThan(0));
    // Integration test uses print for progress output.
    // ignore: avoid_print
    print('  Call 1: ${r.value?.dartValue}');
  }, timeout: const Timeout(Duration(seconds: 15)));

  test(
    'call 2 — HTTP still works (same session)',
    () async {
      final r = await session.execute(
        'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
      );
      expect(r.value?.dartValue, isA<String>());
      // Integration test uses print for progress output.
      // ignore: avoid_print
      print('  Call 2: ${r.value?.dartValue}');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'call 3 — state persists across HTTP calls',
    () async {
      await session.execute(
        'first = http_get("https://demo.toughserv.com/api/v1/installation/versions")',
      );
      final r = await session.execute('len(first)');
      expect(r.value?.dartValue, greaterThan(0));
      // Integration test uses print for progress output.
      // ignore: avoid_print
      print('  Call 3: first has ${r.value?.dartValue} chars');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'call 4 — another HTTP after state persistence',
    () async {
      final r = await session.execute(
        'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
      );
      expect(r.value?.dartValue, isA<String>());
      // Integration test uses print for progress output.
      // ignore: avoid_print
      print('  Call 4: ${r.value?.dartValue}');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'call 5 — five sequential HTTP in one execute',
    () async {
      final r = await session.execute('''
results = []
for i in range(5):
    r = http_get("https://demo.toughserv.com/api/v1/installation/versions")
    results.append(len(r))
results
''');
      final results = r.value!.dartValue! as List<dynamic>;
      expect(results, hasLength(5));
      for (final len in results) {
        expect(len as int, greaterThan(0));
      }
      // Integration test uses print for progress output.
      // ignore: avoid_print
      print('  Call 5: 5 HTTP calls in one execute, lengths=$results');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
