/// Regression test for #271: NativeFinalizer race on handle address reuse.
///
/// Creates and disposes multiple AgentSession instances in rapid succession,
/// then verifies the next session works correctly with HTTP host functions.
/// Before the fix, this would SEGFAULT because a stale GC finalizer freed
/// a live handle whose address matched a previously-freed one.
@Tags(['integration'])
library;

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

HostFunction _httpFn() => HostFunction(
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
          final body =
              await resp.transform(const SystemEncoding().decoder).join();

          return body.substring(0, 30);
        } finally {
          client.close();
        }
      },
    );

HostFunction _syncFn() => HostFunction(
      schema: const HostFunctionSchema(
        name: 'sync_fn',
        description: 'Returns immediately',
      ),
      handler: (_) async => 'ok',
    );

void main() {
  group('NativeFinalizer handle race (#271)', () {
    test(
      'create/dispose 5 sessions then HTTP on 6th',
      () async {
        // Create and dispose 5 sessions to trigger GC finalizer race.
        for (var i = 0; i < 5; i++) {
          final s = AgentSession()..register(_syncFn());
          await s.execute('sync_fn()');
          await s.dispose();
        }

        // 6th session with HTTP — crashed before the fix.
        final s = AgentSession()..register(_httpFn());
        final r = await s.execute('http_fn()');
        await s.dispose();
        print('  result: ${r.value?.dartValue}');
        expect(r.value?.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'create/dispose 10 sessions with HTTP each',
      () async {
        for (var i = 0; i < 10; i++) {
          final s = AgentSession()..register(_httpFn());
          final r = await s.execute('http_fn()');
          await s.dispose();
          expect(r.value?.dartValue, isA<String>());
        }
        print('  10/10 sessions with HTTP passed');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'interleaved sync and HTTP sessions',
      () async {
        for (var i = 0; i < 10; i++) {
          final s = AgentSession()
            ..register(_syncFn())
            ..register(_httpFn());
          if (i.isEven) {
            await s.execute('sync_fn()');
          } else {
            await s.execute('http_fn()');
          }
          await s.dispose();
        }
        print('  10/10 interleaved sessions passed');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'rapid create/dispose without execute',
      () async {
        // Rapid lifecycle without using the session — tests GC pressure.
        for (var i = 0; i < 20; i++) {
          final s = AgentSession()..register(_syncFn());
          await s.dispose();
        }

        // Then one real session with HTTP.
        final s = AgentSession()..register(_httpFn());
        final r = await s.execute('http_fn()');
        await s.dispose();
        print('  survived 20 rapid dispose + 1 HTTP');
        expect(r.value?.dartValue, isA<String>());
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'sandbox mode: 10 execute calls with HTTP',
      () async {
        final s = AgentSession(sandbox: true)..register(_httpFn());
        for (var i = 0; i < 10; i++) {
          final r = await s.execute('http_fn()');
          expect(r.value?.dartValue, isA<String>());
        }
        await s.dispose();
        print('  10/10 sandbox HTTP calls passed');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}
