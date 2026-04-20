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
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fast_fn',
            description: 'Returns immediately',
          ),
          handler: (_, __) async => 'fast',
        ),
      );

      final r1 = await session.execute('fast_fn()').result;
      expect(r1.value.dartValue, 'fast');

      final r2 = await session.execute('fast_fn()').result;
      expect(r2.value.dartValue, 'fast');
    });

    test('async host function with short delay — two calls', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_100ms',
            description: 'Waits 100ms',
          ),
          handler: (_, __) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));

            return 'done';
          },
        ),
      );

      final r1 = await session.execute('delay_100ms()').result;
      expect(r1.value.dartValue, 'done');

      final r2 = await session.execute('delay_100ms()').result;
      expect(r2.value.dartValue, 'done');
    });

    test('async host function with 1s delay — two calls', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_1s',
            description: 'Waits 1 second',
          ),
          handler: (_, __) async {
            await Future<void>.delayed(const Duration(seconds: 1));

            return 'done';
          },
        ),
      );

      final r1 = await session.execute('delay_1s()').result;
      expect(r1.value.dartValue, 'done');

      final r2 = await session.execute('delay_1s()').result;
      expect(r2.value.dartValue, 'done');
    });

    test(
      'async host function with real HTTP — two calls',
      () async {
        final session = MontyRuntime();
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
            handler: (args, _) async {
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
        ).result;
        expect(r1.value.dartValue, isA<String>());
        expect(r1.value.dartValue, isNotEmpty);

        // This is the call that crashes on #271
        final r2 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        expect(r2.value.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'sandbox mode — async HTTP — two calls',
      () async {
        final session = MontyRuntime(sandbox: true);
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
            handler: (args, _) async {
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
        ).result;
        expect(r1.value.dartValue, isA<String>());

        final r2 = await session.execute(
          'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        expect(r2.value.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
    test('file I/O — two calls', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'read_file',
            description: 'Reads a file',
          ),
          handler: (_, __) async {
            final file = File('/etc/hosts');
            final content = await file.readAsString();

            return content.substring(0, 20);
          },
        ),
      );

      final r1 = await session.execute('read_file()').result;
      expect(r1.value.dartValue, isA<String>());

      final r2 = await session.execute('read_file()').result;
      expect(r2.value.dartValue, isA<String>());
    });

    test('process I/O — two calls', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'run_cmd',
            description: 'Runs a command',
          ),
          handler: (_, __) async {
            final result = await Process.run('echo', ['hello']);

            return (result.stdout as String).trim();
          },
        ),
      );

      final r1 = await session.execute('run_cmd()').result;
      expect(r1.value.dartValue, 'hello');

      final r2 = await session.execute('run_cmd()').result;
      expect(r2.value.dartValue, 'hello');
    });

    test('socket listen — two calls', () async {
      final session = MontyRuntime();
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'socket_test',
            description: 'Opens and closes a socket',
          ),
          handler: (_, __) async {
            final server = await ServerSocket.bind('127.0.0.1', 0);
            final port = server.port;
            await server.close();

            return 'port:$port';
          },
        ),
      );

      final r1 = await session.execute('socket_test()').result;
      expect(r1.value.dartValue, startsWith('port:'));

      final r2 = await session.execute('socket_test()').result;
      expect(r2.value.dartValue, startsWith('port:'));
    });

    test(
      'http but return small string — two calls',
      () async {
        final session = MontyRuntime();
        addTearDown(session.dispose);

        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'http_tiny',
              description: 'HTTP GET, returns status code only',
              params: [
                HostParam(name: 'url', type: HostParamType.string),
              ],
            ),
            handler: (args, _) async {
              final url = args['url']! as String;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                // Drain the body without reading it
                await response.drain<void>();

                return response.statusCode;
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session.execute(
          'http_tiny("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        expect(r1.value.dartValue, 200);

        final r2 = await session.execute(
          'http_tiny("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        expect(r2.value.dartValue, 200);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'http returning large string — two calls',
      () async {
        final session = MontyRuntime();
        addTearDown(session.dispose);

        session.register(
          HostFunction(
            schema: const HostFunctionSchema(
              name: 'http_large',
              description: 'HTTP GET, returns full body',
              params: [
                HostParam(name: 'url', type: HostParamType.string),
              ],
            ),
            handler: (args, _) async {
              final url = args['url']! as String;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                final body = await response
                    .transform(const SystemEncoding().decoder)
                    .join();

                return body;
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session.execute(
          'http_large("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        final v1 = r1.value.dartValue! as String;
        expect(v1.length, greaterThan(10));

        final r2 = await session.execute(
          'http_large("https://demo.toughserv.com/api/v1/installation/versions")',
        ).result;
        expect(r2.value.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
