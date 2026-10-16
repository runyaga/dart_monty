/// Tests raw bridge.execute() with HTTP host functions.
/// No MontyRuntime state wrapping — isolates whether the bug is in state
/// wrapping or in the FFI/bridge layer itself.
@Tags(['integration'])
library;

// Integration test uses print for progress output.
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:test/test.dart';

import '_worker.dart';

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

/// The pool the runtime tests check out from.
late Monty pool;

void main() {
  setUpAll(() async => pool = await startTestPool());
  tearDownAll(() => pool.close());

  test(
    'MontyBridge.execute — 3 sequential HTTP calls',
    () async {
      final pool = await startTestPool();
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      final bridge = MontyBridge(session: session)..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final events = await bridge.execute('http_get("$_url")').toList();
        final finished = events.whereType<BridgeRunFinished>().first;
        print('  bridge.execute call $i: ${finished.value}');
        expect(finished.value, isA<String>());
      }

      bridge.dispose();
      await session.close();
      await pool.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'MontyBridge.execute — 3 sequential HTTP calls, value extraction',
    () async {
      final pool = await startTestPool();
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      final bridge = MontyBridge(session: session)..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final events = await bridge.execute('http_get("$_url")').toList();
        final finished = events.whereType<BridgeRunFinished>().first;
        print('  bridge call $i value: ${finished.value}');
        expect(finished.value, isA<String>());
      }

      bridge.dispose();
      await session.close();
      await pool.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'MontyRuntime shared mode (no sandbox) — 3 sequential HTTP calls',
    () async {
      final session = (await MontyRuntime.start(pool: pool))
        ..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")').result;
        print('  session.execute call $i: ${result.dartValue}');
        expect(result.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'MontyRuntime sandbox mode — 3 sequential HTTP calls',
    () async {
      final session = (await MontyRuntime.start(pool: pool, sandbox: true))
        ..register(_httpGetFn());

      for (var i = 1; i <= 3; i++) {
        final result = await session.execute('http_get("$_url")').result;
        print('  sandbox.execute call $i: ${result.dartValue}');
        expect(result.dartValue, isA<String>());
      }

      await session.dispose();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
