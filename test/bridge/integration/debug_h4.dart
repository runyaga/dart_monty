// ignore_for_file: avoid_print
/// Standalone reproduction of H4 crash for debugging under lldb.
///
/// Run under lldb:
///   lldb -- dart run test/bridge/integration/debug_h4.dart
///   (lldb) run
///   (lldb) bt    # after crash — shows full native + Dart stack
///
/// Or with MallocScribble (fills freed memory with 0x55):
///   MallocScribble=1 dart run test/bridge/integration/debug_h4.dart
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
  print('Creating AgentSession with HTTP + Template + MsgBus...');

  final session = AgentSession(
    plugins: [DinjaTemplatePlugin(), MessageBusPlugin()],
  )..register(
      HostFunction(
        schema: const HostFunctionSchema(
          name: 'http_fn',
          description: 'HTTP GET',
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

  print('Call 1: execute http_fn...');
  final r1 = await session.execute('data = http_fn()');
  print('  result: ${r1.value?.dartValue ?? r1.error}');

  print('Call 2: execute template...');
  final r2 = await session.execute(
    'report = tmpl_render("Got {{n}} bytes", {"n": len(data)})',
  );
  print('  result: ${r2.value?.dartValue ?? r2.error}');

  print('Call 3: execute msg_send...');
  final r3 = await session.execute('msg_send("log", report)');
  print('  result: ${r3.value?.dartValue ?? r3.error}');

  print('Call 4: execute msg_recv (THIS USUALLY CRASHES)...');
  final r4 = await session.execute('msg_recv("log")');
  print('  result: ${r4.value?.dartValue ?? r4.error}');

  print('All 4 calls completed without crash!');
  await session.dispose();
}
