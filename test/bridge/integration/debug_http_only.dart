// ignore_for_file: avoid_print
/// Minimal: just HTTP, multiple execute() calls, no zones, no sync.
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  final session = AgentSession()
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
                'https://demo.toughserv.com/api/v1/installation/versions',
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
    );

  for (var i = 0; i < 5; i++) {
    print('Call $i...');
    final r = await session.execute('http_fn()');
    print('  result: ${r.value?.dartValue ?? "null (${r.error})"}');
  }

  await session.dispose();
  print('DONE');
}
