/// FFI integration tests for CronPlugin, StoragePlugin, LoggingPlugin,
/// and HttpPlugin through a real AgentSession.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/new_plugins_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

const _testUrl = 'https://demo.toughserv.com/api/v1/installation/versions';

void main() {
  // ---------------------------------------------------------------------------
  // StoragePlugin
  // ---------------------------------------------------------------------------

  group('StoragePlugin — FFI', () {
    late AgentSession session;
    late StoragePlugin storage;

    setUp(() {
      storage = StoragePlugin();
      session = AgentSession(plugins: [storage]);
    });
    tearDown(() async => session.dispose());

    test('storage_set / storage_get round-trip', () async {
      final r = await session.execute('''
storage_set(key='name', value='alice')
storage_get(key='name')
''');
      expect(r.error, isNull);
      expect(r.value.dartValue, 'alice');
    });

    test('storage_set integer value', () async {
      await session.execute("storage_set(key='count', value=42)");
      final r = await session.execute("storage_get(key='count')");
      expect(r.error, isNull);
      expect(r.value.dartValue, 42);
    });

    test('storage_list returns stored keys', () async {
      await session.execute('''
storage_set(key='a', value=1)
storage_set(key='b', value=2)
''');
      final r = await session.execute('storage_list()');
      expect(r.error, isNull);
      final keys = r.value.dartValue! as List;
      expect(keys, containsAll(['a', 'b']));
    });

    test('storage_delete removes key', () async {
      await session.execute("storage_set(key='tmp', value='x')");
      await session.execute("storage_delete(key='tmp')");
      final r = await session.execute("storage_get(key='tmp')");
      expect(r.error, isNull);
      expect(r.value.dartValue, isNull);
    });

    test('storage_has returns bool', () async {
      await session.execute("storage_set(key='present', value=True)");
      final yes = await session.execute("storage_has(key='present')");
      final no = await session.execute("storage_has(key='absent')");
      expect(yes.value.dartValue, true);
      expect(no.value.dartValue, false);
    });

    test('storageSignal updates after execute', () async {
      expect(storage.storageSignal.value, isEmpty);
      await session.execute("storage_set(key='reactive', value='yes')");
      expect(storage.storageSignal.value, contains('reactive'));
    });

    test('VFS path write/read round-trip', () async {
      final r = await session.execute('''
from pathlib import Path
Path('/storage/note.txt').write_text('hello vfs')
Path('/storage/note.txt').read_text()
''');
      expect(r.error, isNull);
      expect(r.value.dartValue, 'hello vfs');
    });

    test('VFS write updates storageSignal', () async {
      await session.execute('''
from pathlib import Path
Path('/storage/vfs_key.txt').write_text('data')
''');
      expect(storage.storageSignal.value, contains('vfs_key.txt'));
    });
  });

  // ---------------------------------------------------------------------------
  // CronPlugin
  // ---------------------------------------------------------------------------

  group('CronPlugin — FFI', () {
    late MessageBus bus;
    late CronPlugin cron;
    late AgentSession session;

    setUp(() {
      bus = MessageBus();
      cron = CronPlugin(bus: bus);
      session = AgentSession(
        plugins: [
          cron,
          MessageBusPlugin(bus: bus),
        ],
      );
    });
    tearDown(() async => session.dispose());

    test('cron_schedule fires payload on MessageBus', () async {
      final r = await session.execute(
        "cron_schedule(expression='periodic:5', channel='ticks', label='t1')",
      );
      expect(r.error, isNull);
      final jobId = r.value.dartValue! as String;
      expect(jobId, startsWith('job_'));

      final msg = await bus
          .channel('ticks')
          .recv()
          .timeout(const Duration(seconds: 2));
      final payload = msg! as Map<String, Object?>;
      expect(payload['job_id'], jobId);
      expect(payload['label'], 't1');
      expect(payload['fire_count'], 1);
    });

    test('cron_cancel stops further fires', () async {
      final r = await session.execute(
        "cron_schedule(expression='periodic:5', channel='c_test')",
      );
      final jobId = r.value.dartValue! as String;

      await bus.channel('c_test').recv().timeout(const Duration(seconds: 2));

      await session.execute("cron_cancel(job_id='$jobId')");

      Object? second;
      try {
        second = await bus
            .channel('c_test')
            .recv()
            .timeout(const Duration(milliseconds: 100));
      } on TimeoutException {
        second = null;
      }
      expect(second, isNull, reason: 'no further fires after cancel');
    });

    test('cron_list returns registered jobs', () async {
      await session.execute(
        "cron_schedule(expression='periodic:1000', channel='l_test')",
      );
      final r = await session.execute('cron_list()');
      expect(r.error, isNull);
      final jobs = r.value.dartValue! as List;
      expect(jobs, isNotEmpty);
      expect((jobs.first as Map)['channel'], 'l_test');
    });

    test('delay job fires exactly once', () async {
      await session.execute(
        "cron_schedule(expression='delay:5', channel='once')",
      );
      final first = await bus
          .channel('once')
          .recv()
          .timeout(const Duration(seconds: 2));
      expect((first! as Map)['fire_count'], 1);

      Object? second;
      try {
        second = await bus
            .channel('once')
            .recv()
            .timeout(const Duration(milliseconds: 150));
      } on TimeoutException {
        second = null;
      }
      expect(second, isNull, reason: 'delay job fires only once');
    });
  });

  // ---------------------------------------------------------------------------
  // LoggingPlugin
  // ---------------------------------------------------------------------------

  group('LoggingPlugin — FFI', () {
    late LoggingPlugin logging;
    late AgentSession session;

    setUp(() {
      logging = LoggingPlugin(forwardToBridgeLogger: false);
      session = AgentSession(plugins: [logging]);
    });
    tearDown(() async => session.dispose());

    test('direct log_event_batch delivers records', () async {
      await session.execute('''
log_event_batch(batch=[
  {'level': 20, 'logger': 'app', 'message': 'hello from ffi'},
  {'level': 40, 'logger': 'app', 'message': 'error event', 'exc_info': None},
])
''');
      final logs = logging.logSignal.value;
      expect(logs, hasLength(2));
      expect(logs[0].message, 'hello from ffi');
      expect(logs[0].level, 20);
      expect(logs[1].level, 40);
    });

    // NOTE: LoggingPlugin.pythonPreamble defines a Python class (_MontyHandler)
    // which Monty's parser does not support (class definitions are not yet
    // implemented). The preamble is intended for use with full CPython runtimes
    // only. Integration tests for the preamble path are therefore omitted here.

    test('records accumulate across execute calls', () async {
      await session.execute(
        'log_event_batch(batch='
        "[{'level': 20, 'logger': 'a', 'message': 'one'}])",
      );
      await session.execute(
        'log_event_batch(batch='
        "[{'level': 20, 'logger': 'a', 'message': 'two'}])",
      );
      expect(logging.logSignal.value, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // HttpPlugin
  // ---------------------------------------------------------------------------

  group(
    'HttpPlugin — FFI',
    () {
      late HttpPlugin http;
      late AgentSession session;

      setUp(() {
        http = HttpPlugin();
        session = AgentSession(plugins: [http]);
      });
      tearDown(() async => session.dispose());

      test('http_get returns ok response', () async {
        final r = await session.execute("http_get(url='$_testUrl')");
        expect(r.error, isNull);
        final result = r.value.dartValue! as Map;
        expect(result['ok'], isTrue);
        expect(result['status_code'], 200);
        expect(result['text'], isA<String>());
      });

      test('http_get result accessible as Python dict', () async {
        final r = await session.execute('''
resp = http_get(url='$_testUrl')
resp['ok']
''');
        expect(r.error, isNull);
        expect(r.value.dartValue, true);
      });

      test('totalRequestsSignal increments per call', () async {
        expect(http.totalRequestsSignal.value, 0);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalRequestsSignal.value, 1);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalRequestsSignal.value, 2);
      });

      test('totalBytesDownloadedSignal increases', () async {
        expect(http.totalBytesDownloadedSignal.value, 0);
        await session.execute("http_get(url='$_testUrl')");
        expect(http.totalBytesDownloadedSignal.value, greaterThan(0));
      });

      test('unreachable host surfaces an error', () async {
        final r = await session.execute(
          "http_get(url='http://localhost:19999')",
        );
        final isError =
            r.error != null ||
            (r.value.dartValue is Map &&
                (r.value.dartValue! as Map)['ok'] == false);
        expect(isError, isTrue, reason: 'unreachable host must surface error');
      });
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
