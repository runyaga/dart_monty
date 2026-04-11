/// Tests raw bridge.execute() and Monty.run() with HTTP host functions.
/// No AgentSession state wrapping — isolates whether the bug is in state
/// wrapping or in the FFI/bridge layer itself.
@Tags(['integration'])
library;

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:test/test.dart';

HostFunction _httpGetFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'http_get',
    description: 'Fetches a URL',
    params: [HostParam(name: 'url', type: HostParamType.string)],
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

      return body.substring(0, 50);
    } finally {
      client.close();
    }
  },
);

const _url = 'https://demo.toughserv.com/api/v1/installation/versions';

void main() {
  test(
    'DefaultMontyBridge.execute — 3 sequential HTTP calls',
    () async {
      final monty = Monty();
      final bridge = DefaultMontyBridge(
        platform: monty.platform,
        useFutures: false,
      );
      bridge.register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final events = await bridge.execute('http_get("$_url")').toList();
        final finished = events.whereType<BridgeRunFinished>().first;
        print('  bridge.execute call $i: ${finished.value}');
        expect(finished.value, isA<String>());
      }

      bridge.dispose();
      await monty.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Monty.run — 3 sequential HTTP calls',
    () async {
      final monty = Monty();
      final bridge = DefaultMontyBridge(
        platform: monty.platform,
        useFutures: false,
      );
      bridge.register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await monty.run('http_get("$_url")');
        print('  monty.run call $i: ${result.value?.dartValue}');
        expect(result.value?.dartValue, isA<String>());
      }

      bridge.dispose();
      await monty.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'AgentSession shared mode (no sandbox) — 3 sequential HTTP calls',
    () async {
      final session = AgentSession();
      session.register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")');
        print('  session.execute call $i: ${result.value?.dartValue}');
        expect(result.value?.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'AgentSession sandbox mode — 3 sequential HTTP calls',
    () async {
      final session = AgentSession(sandbox: true);
      session.register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")');
        print('  sandbox.execute call $i: ${result.value?.dartValue}');
        expect(result.value?.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
