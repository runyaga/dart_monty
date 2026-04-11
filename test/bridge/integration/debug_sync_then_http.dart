// ignore_for_file: avoid_print
/// Narrowing: how many sync calls before HTTP breaks?
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  for (final syncCount in [0, 1, 2, 3, 5, 10, 20]) {
    print('=== $syncCount sync calls then 2 HTTP ===');
    final session = AgentSession()
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'sync_fn',
            description: 'sync',
          ),
          handler: (_) async => 'ok',
        ),
      )
      ..register(
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'http_fn',
            description: 'HTTP',
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

              return body.substring(0, 20);
            } finally {
              client.close();
            }
          },
        ),
      );

    // Do N sync calls
    for (var i = 0; i < syncCount; i++) {
      await session.execute('sync_fn()');
    }
    print('  $syncCount sync calls done');

    // Then 2 HTTP calls
    for (var i = 0; i < 2; i++) {
      final r = await session.execute('http_fn()');
      final v = r.value?.dartValue;
      print('  http $i: ${v ?? "NULL/ERROR"}');
      if (v == null) {
        print('  FAILED at http $i after $syncCount sync calls');
        await session.dispose();

        return;
      }
    }
    print('  PASSED\n');
    await session.dispose();
  }
  print('ALL PASSED');
}
