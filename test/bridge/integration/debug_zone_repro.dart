// ignore_for_file: avoid_print
/// Minimal reproduction: does Zone.fork affect AgentSession execute?
///
/// Run: dart run test/bridge/integration/debug_zone_repro.dart
import 'dart:async';
import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';

Future<void> main() async {
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

  // Test 1: No zones — 10 sync calls
  print('=== Test 1: No zones, 10 sync ===');
  for (var i = 0; i < 10; i++) {
    final r = await session.execute('sync_fn()');
    assert(r.value?.dartValue == 'ok', 'call $i failed: ${r.value?.dartValue}');
  }
  print('  PASS: 10/10\n');

  // Test 2: Zone.fork per call — 10 sync calls
  print('=== Test 2: Zone.fork, 10 sync ===');
  for (var i = 0; i < 10; i++) {
    final r = await Zone.current.fork().run(() async {
      return session.execute('sync_fn()');
    });
    assert(r.value?.dartValue == 'ok', 'zone call $i failed');
  }
  print('  PASS: 10/10\n');

  // Test 3: No zones — 5 HTTP calls
  print('=== Test 3: No zones, 5 HTTP ===');
  for (var i = 0; i < 5; i++) {
    final r = await session.execute('http_fn()');
    final v = r.value?.dartValue;
    print('  call $i: ${v ?? "null (error: ${r.error})"}');
    assert(v != null, 'http call $i returned null');
  }
  print('  PASS: 5/5\n');

  // Test 4: Zone.fork per call — 5 HTTP calls
  print('=== Test 4: Zone.fork, 5 HTTP ===');
  for (var i = 0; i < 5; i++) {
    final r = await Zone.current.fork().run(() async {
      return session.execute('http_fn()');
    });
    final v = r.value?.dartValue;
    print('  zone call $i: ${v ?? "null (error: ${r.error})"}');
  }
  print('  Done\n');

  // Test 5: Zone.fork with error handler — 5 HTTP calls
  print('=== Test 5: Zone.fork + errorHandler, 5 HTTP ===');
  for (var i = 0; i < 5; i++) {
    final completer = Completer<MontyResult>();
    Zone.current
        .fork(
          specification: ZoneSpecification(
            handleUncaughtError: (self, parent, zone, error, stack) {
              print('  UNCAUGHT in zone $i: $error');
              if (!completer.isCompleted) {
                completer.completeError(error, stack);
              }
            },
          ),
        )
        .run(() async {
          try {
            final r = await session.execute('http_fn()');
            if (!completer.isCompleted) completer.complete(r);
          } catch (e, s) {
            if (!completer.isCompleted) completer.completeError(e, s);
          }
        });
    try {
      final r = await completer.future;
      final v = r.value?.dartValue;
      print('  errzone call $i: ${v ?? "null"}');
    } catch (e) {
      print('  errzone call $i: ERROR $e');
    }
  }
  print('  Done\n');

  await session.dispose();
  print('ALL DONE — session disposed cleanly');
}
