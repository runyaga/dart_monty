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
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

void main() {
  late Monty pool;
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  group('FFI async host function regression (#271)', () {
    test('sync host function — two sequential calls work', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'fast_fn',
            description: 'Returns immediately',
          ),
          handler: (_, _) async => const MontyString('fast'),
        ),
      );

      final r1 = await session.execute('fast_fn()').result;
      expect(r1.dartValue, 'fast');

      final r2 = await session.execute('fast_fn()').result;
      expect(r2.dartValue, 'fast');
    });

    test('async host function with short delay — two calls', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_100ms',
            description: 'Waits 100ms',
          ),
          handler: (_, _) async {
            await Future<void>.delayed(const Duration(milliseconds: 100));

            return const MontyString('done');
          },
        ),
      );

      final r1 = await session.execute('delay_100ms()').result;
      expect(r1.dartValue, 'done');

      final r2 = await session.execute('delay_100ms()').result;
      expect(r2.dartValue, 'done');
    });

    test('async host function with 1s delay — two calls', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'delay_1s',
            description: 'Waits 1 second',
          ),
          handler: (_, _) async {
            await Future<void>.delayed(const Duration(seconds: 1));

            return const MontyString('done');
          },
        ),
      );

      final r1 = await session.execute('delay_1s()').result;
      expect(r1.dartValue, 'done');

      final r2 = await session.execute('delay_1s()').result;
      expect(r2.dartValue, 'done');
    });

    test(
      'async host function with real HTTP — two calls',
      () async {
        final session = await MontyRuntime.start(pool: pool);
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
              final url = (args['url']! as MontyString).value;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                final body = await response
                    .transform(
                      const SystemEncoding().decoder,
                    )
                    .join();

                return MontyValue.fromDart(body.substring(0, 50));
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session
            .execute(
              'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        final isString = isA<String>();
        expect(r1.dartValue, isString);
        expect(r1.dartValue, isNotEmpty);

        // This is the call that crashes on #271
        final r2 = await session
            .execute(
              'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        expect(r2.dartValue, isString);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'sandbox mode — async HTTP — two calls',
      () async {
        final session = await MontyRuntime.start(pool: pool, sandbox: true);
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
              final url = (args['url']! as MontyString).value;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                final body = await response
                    .transform(
                      const SystemEncoding().decoder,
                    )
                    .join();

                return MontyValue.fromDart(body.substring(0, 50));
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session
            .execute(
              'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        final isString = isA<String>();
        expect(r1.dartValue, isString);

        final r2 = await session
            .execute(
              'http_get("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        expect(r2.dartValue, isString);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
    test('file I/O — two calls', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'read_file',
            description: 'Reads a file',
          ),
          handler: (_, _) async {
            final file = File('/etc/hosts');
            final content = await file.readAsString();

            return MontyValue.fromDart(content.substring(0, 20));
          },
        ),
      );

      final r1 = await session.execute('read_file()').result;
      final isString = isA<String>();
      expect(r1.dartValue, isString);

      final r2 = await session.execute('read_file()').result;
      expect(r2.dartValue, isString);
    });

    test('process I/O — two calls', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'run_cmd',
            description: 'Runs a command',
          ),
          handler: (_, _) async {
            final result = await Process.run('echo', ['hello']);

            return MontyValue.fromDart((result.stdout as String).trim());
          },
        ),
      );

      final r1 = await session.execute('run_cmd()').result;
      expect(r1.dartValue, 'hello');

      final r2 = await session.execute('run_cmd()').result;
      expect(r2.dartValue, 'hello');
    });

    test('socket listen — two calls', () async {
      final session = await MontyRuntime.start(pool: pool);
      addTearDown(session.dispose);

      session.register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'socket_test',
            description: 'Opens and closes a socket',
          ),
          handler: (_, _) async {
            final server = await ServerSocket.bind('127.0.0.1', 0);
            final port = server.port;
            await server.close();

            return MontyString('port:$port');
          },
        ),
      );

      final r1 = await session.execute('socket_test()').result;
      final startsWithPort = startsWith('port:');
      expect(r1.dartValue, startsWithPort);

      final r2 = await session.execute('socket_test()').result;
      expect(r2.dartValue, startsWithPort);
    });

    test(
      'http but return small string — two calls',
      () async {
        final session = await MontyRuntime.start(pool: pool);
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
              final url = (args['url']! as MontyString).value;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                // Drain the body without reading it
                await response.drain<void>();

                return MontyValue.fromDart(response.statusCode);
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session
            .execute(
              'http_tiny("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        expect(r1.dartValue, 200);

        final r2 = await session
            .execute(
              'http_tiny("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        expect(r2.dartValue, 200);
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'http returning large string — two calls',
      () async {
        final session = await MontyRuntime.start(pool: pool);
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
              final url = (args['url']! as MontyString).value;
              final client = HttpClient();
              try {
                final request = await client.getUrl(Uri.parse(url));
                final response = await request.close();
                final body = await response
                    .transform(const SystemEncoding().decoder)
                    .join();

                return MontyValue.fromDart(body);
              } finally {
                client.close();
              }
            },
          ),
        );

        final r1 = await session
            .execute(
              'http_large("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        final v1 = r1.dartValue! as String;
        expect(v1.length, greaterThan(10));

        final r2 = await session
            .execute(
              'http_large("https://demo.toughserv.com/api/v1/installation/versions")',
            )
            .result;
        expect(r2.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
