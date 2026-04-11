/// Reproduces #271: SEGFAULT on sequential async host function calls.
///
/// The crash occurs when a host function does real async I/O (takes > 100ms)
/// and then a second execute() call is made. No soliplex dependency — pure
/// dart_monty reproduction.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration test/bridge/integration/ffi_async_host_fn_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('FFI async host function regression (#271)', () {
    test('sync host function — two sequential calls work', () async {
      final session = AgentSession();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fast_fn',
            description: 'Returns immediately',
          ),
          handler: (_) async => 'fast',
        ),
      );

      final r1 = await session.execute('fast_fn()');
      expect(r1.value?.dartValue, 'fast');

      final r2 = await session.execute('fast_fn()');
      expect(r2.value?.dartValue, 'fast');
    });

    test('async host function with short delay — two calls', () async {
      final session = AgentSession();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_100ms',
            description: 'Waits 100ms',
          ),
          handler: (_) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));

            return 'done';
          },
        ),
      );

      final r1 = await session.execute('delay_100ms()');
      expect(r1.value?.dartValue, 'done');

      final r2 = await session.execute('delay_100ms()');
      expect(r2.value?.dartValue, 'done');
    });

    test('async host function with 1s delay — two calls', () async {
      final session = AgentSession();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_1s',
            description: 'Waits 1 second',
          ),
          handler: (_) async {
            await Future<void>.delayed(const Duration(seconds: 1));

            return 'done';
          },
        ),
      );

      final r1 = await session.execute('delay_1s()');
      expect(r1.value?.dartValue, 'done');

      final r2 = await session.execute('delay_1s()');
      expect(r2.value?.dartValue, 'done');
    });

    test(
      'async host function with real HTTP — two calls',
      () async {
        final session = AgentSession();
        addTearDown(session.dispose);

        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'http_get',
              description: 'Fetches a URL',
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
                    .transform(
                      const SystemEncoding().decoder,
                    )
                    .join();

                return body.substring(0, 50);
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        );
        expect(r1.value?.dartValue, isA<String>());
        expect(r1.value?.dartValue, isNotEmpty);

        // This is the call that crashes on #271
        final r2 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        );
        expect(r2.value?.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'sandbox mode — async HTTP — two calls',
      () async {
        final session = AgentSession(sandbox: true);
        addTearDown(session.dispose);

        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'http_get',
              description: 'Fetches a URL',
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
                    .transform(
                      const SystemEncoding().decoder,
                    )
                    .join();

                return body.substring(0, 50);
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        );
        expect(r1.value?.dartValue, isA<String>());

        final r2 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        );
        expect(r2.value?.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
