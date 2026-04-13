/// FFI integration tests for CronPlugin through a real AgentSession.
///
/// Run with:
/// ```bash
/// dart test --run-skipped --tags=integration \
///   test/bridge/integration/cron_plugin_integration_test.dart
/// ```
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

void main() {
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
}
