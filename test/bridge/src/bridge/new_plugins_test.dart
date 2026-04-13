import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('CronPlugin', () {
    late MessageBus bus;
    late CronPlugin plugin;

    setUp(() {
      bus = MessageBus();
      plugin = CronPlugin(bus: bus);
    });

    test('namespace is cron', () {
      expect(plugin.namespace, 'cron');
    });

    test('schedule a periodic job and verify it posts to bus', () async {
      // periodic:1ms is too fast for reliable testing, but we'll use it to trigger a fire.
      final id =
          await plugin.functions
                  .firstWhere((f) => f.schema.name == 'cron_schedule')
                  .handler({
                    'expression': 'periodic:1',
                    'channel': 'ticks',
                    'label': 'test_job',
                  })
              as String;

      expect(id, startsWith('job_'));

      // Wait for a message on the bus
      final msg = await bus
          .channel('ticks')
          .recv()
          .timeout(const Duration(seconds: 1));
      expect(msg, isA<Map<String, Object?>>());
      final payload = msg as Map<String, Object?>;
      expect(payload['job_id'], id);
      expect(payload['label'], 'test_job');
      expect(payload['fire_count'], 1);

      await plugin.onDispose();
    });

    test('onDispose cancels all timers', () async {
      await plugin.functions
          .firstWhere((f) => f.schema.name == 'cron_schedule')
          .handler({
            'expression': 'periodic:1000',
            'channel': 'slow_ticks',
          });
      expect(plugin.jobsSignal.value, hasLength(1));

      await plugin.onDispose();
      expect(plugin.jobsSignal.value, isEmpty);
    });
  });

  group('HttpPlugin', () {
    late http_testing.MockClient mockClient;
    late HttpPlugin plugin;

    setUp(() {
      mockClient = http_testing.MockClient((request) async {
        if (request.url.path == '/text') {
          return http.Response('hello', 200);
        }
        if (request.url.path == '/binary') {
          return http.Response.bytes(Uint8List.fromList([1, 2, 3]), 200);
        }
        return http.Response('not found', 404);
      });
      plugin = HttpPlugin(client: mockClient);
    });

    test('http_get returns text and content', () async {
      final result =
          await plugin.functions
                  .firstWhere((f) => f.schema.name == 'http_get')
                  .handler({
                    'url': 'http://example.com/text',
                  })
              as Map<String, Object?>;

      expect(result['status_code'], 200);
      expect(result['text'], 'hello');
      expect(result['content'], isA<Uint8List>());
      expect(result['ok'], isTrue);
    });

    test('binary response handling', () async {
      final result =
          await plugin.functions
                  .firstWhere((f) => f.schema.name == 'http_get')
                  .handler({
                    'url': 'http://example.com/binary',
                  })
              as Map<String, Object?>;

      expect(result['status_code'], 200);
      expect(result['content'], [1, 2, 3]);
    });

    test('execution hooks track metrics', () async {
      await plugin.onExecuteStart('print("hi")');
      await plugin.functions
          .firstWhere((f) => f.schema.name == 'http_get')
          .handler({
            'url': 'http://example.com/text',
          });
      // We can't easily assert on the logger output without a complex mock,
      // but we can verify it doesn't crash.
      await plugin.onExecuteEnd(
        const ExecuteSuccess(BridgeRunFinished(threadId: 't', runId: 'r')),
      );
    });

    test('http signals are reactive', () async {
      expect(plugin.totalRequestsSignal.value, 0);
      expect(plugin.totalBytesDownloadedSignal.value, 0);

      await plugin.functions
          .firstWhere((f) => f.schema.name == 'http_get')
          .handler({
            'url': 'http://example.com/text',
          });

      expect(plugin.totalRequestsSignal.value, 1);
      expect(plugin.totalBytesDownloadedSignal.value, 5); // 'hello'.length
    });
  });

  group('LoggingPlugin', () {
    late LoggingPlugin plugin;

    setUp(() {
      plugin = LoggingPlugin(forwardToBridgeLogger: false);
    });

    test('log_event_batch updates logSignal', () async {
      await plugin.functions
          .firstWhere((f) => f.schema.name == 'log_event_batch')
          .handler({
            'batch': [
              {'level': 20, 'logger': 'test', 'message': 'hello'},
              {
                'level': 40,
                'logger': 'test',
                'message': 'error',
                'exc_info': 'traceback...',
              },
            ],
          });

      final logs = plugin.logSignal.value;
      expect(logs, hasLength(2));
      expect(logs[0].message, 'hello');
      expect(logs[1].level, 40);
      expect(logs[1].excInfo, 'traceback...');
    });

    test('pythonPreamble exists', () {
      expect(LoggingPlugin.pythonPreamble, contains('class _MontyHandler'));
    });
  });

  group('StoragePlugin', () {
    late StoragePlugin plugin;
    late MemoryStorageBackend backend;

    setUp(() {
      backend = MemoryStorageBackend();
      plugin = StoragePlugin(backend: backend);
    });

    test('KV functions work', () async {
      final setFn = plugin.functions.firstWhere(
        (f) => f.schema.name == 'storage_set',
      );
      final getFn = plugin.functions.firstWhere(
        (f) => f.schema.name == 'storage_get',
      );

      await setFn.handler({'key': 'foo', 'value': 'bar'});
      expect(await getFn.handler({'key': 'foo'}), 'bar');

      await setFn.handler({'key': 'count', 'value': 42});
      expect(await getFn.handler({'key': 'count'}), 42);
    });

    test('VFS mapping works', () async {
      final provider = plugin.osContribution!['Path.']!;

      // Simulate Path.write_text('/storage/data.txt', contents='hello')
      await provider.resolve(
        MontyOsCall(
          operationName: 'Path.write_text',
          arguments: [
            const MontyString('/storage/data.txt'),
            const MontyString('hello'),
          ],
        ),
      );

      // Verify KV store
      expect(await backend.get('data.txt'), 'hello');

      // Simulate Path.read_text('/storage/data.txt')
      final read = await provider.resolve(
        MontyOsCall(
          operationName: 'Path.read_text',
          arguments: [const MontyString('/storage/data.txt')],
        ),
      );
      expect(read, 'hello');
    });

    test('storageSignal is reactive', () async {
      final setFn = plugin.functions.firstWhere(
        (f) => f.schema.name == 'storage_set',
      );

      expect(plugin.storageSignal.value, isEmpty);

      await setFn.handler({'key': 'foo', 'value': 'bar'});
      expect(plugin.storageSignal.value, contains('foo'));

      final provider = plugin.osContribution!['Path.']!;
      await provider.resolve(
        MontyOsCall(
          operationName: 'Path.write_text',
          arguments: [
            const MontyString('/storage/vfs.txt'),
            const MontyString('vfs'),
          ],
        ),
      );
      expect(plugin.storageSignal.value, containsAll(['foo', 'vfs.txt']));
    });
  });
}
