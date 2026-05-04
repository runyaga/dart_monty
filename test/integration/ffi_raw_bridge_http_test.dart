/// Tests raw bridge.execute() and Monty.run() with HTTP host functions.
/// No MontyRuntime state wrapping — isolates whether the bug is in state
/// wrapping or in the FFI/bridge layer itself.
@Tags(['integration'])
library;

// Integration test uses print for progress output.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

HostFunction _httpGetFn() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'http_get',
    description: 'Fetches a URL',
    params: [HostParam(name: 'url', type: HostParamType.string)],
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

      return body.substring(0, 50);
    } finally {
      client.close();
    }
  },
);

const _url = 'https://demo.toughserv.com/api/v1/installation/versions';

void main() {
  test(
    'PlatformBridge.execute — 3 sequential HTTP calls',
    () async {
      final platform = createPlatformMonty();
      final bridge = PlatformBridge(
        platform: platform,
      )..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final events = await bridge.execute('http_get("$_url")').toList();
        final finished = events.whereType<BridgeRunFinished>().first;
        print('  bridge.execute call $i: ${finished.value}');
        expect(finished.value, isA<String>());
      }

      bridge.dispose();
      await platform.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'PlatformBridge.execute — 3 sequential HTTP calls, value extraction',
    () async {
      final platform = createPlatformMonty();
      final bridge = PlatformBridge(
        platform: platform,
      )..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final events = await bridge.execute('http_get("$_url")').toList();
        final finished = events.whereType<BridgeRunFinished>().first;
        print('  bridge call $i value: ${finished.value}');
        expect(finished.value, isA<String>());
      }

      bridge.dispose();
      await platform.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'MontyRuntime shared mode (no sandbox) — 3 sequential HTTP calls',
    () async {
      final session = MontyRuntime()..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")').result;
        print('  session.execute call $i: ${result.value.dartValue}');
        expect(result.value.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'MontyRuntime sandbox mode — 3 sequential HTTP calls',
    () async {
      final session = MontyRuntime(sandbox: true)..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")').result;
        print('  sandbox.execute call $i: ${result.value.dartValue}');
        expect(result.value.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
