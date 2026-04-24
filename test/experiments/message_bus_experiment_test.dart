// G6: MessageBus extension experiments.
//
// Covers Dart↔Python messaging, peek, close, high-volume throughput,
// multiple channels, timeout recv, channel stats signals, and FauxUi.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/message_bus_experiment_test.dart
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // G6-1: Python sends, Dart receives
  // ---------------------------------------------------------------------------

  group('G6-1: Python sends → Dart receives', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python msg_send, Dart reads via bus.recv', () async {
      // Start execution — Python sends then returns.
      await h.run("msg_send(name='out', message={'result': 42})");

      final msg = (await bus.recv('out'))! as Map;
      expect(msg['result'], 42);
    });

    test('Python sends multiple messages — Dart drains in order', () async {
      await h.run('''
for i in range(5):
    msg_send(name='nums', message=i)
''');

      final results = <Object?>[];
      for (var i = 0; i < 5; i++) {
        results.add(await bus.recv('nums'));
      }
      expect(results, [0, 1, 2, 3, 4]);
    });
  });

  // ---------------------------------------------------------------------------
  // G6-2: Dart sends, Python receives
  // ---------------------------------------------------------------------------

  group('G6-2: Dart sends → Python receives', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Dart pre-queues message, Python reads with msg_recv', () async {
      bus.send('tasks', {'job': 'compress', 'file': 'data.csv'});

      final result = await h.run('''
task = msg_recv(name='tasks')
task['job']
''');

      expect(result.error, isNull);
      expect(result.value.dartValue, 'compress');
    });

    test('Dart sends concurrently with Python msg_recv blocking', () async {
      const script = "msg_recv(name='async_ch')";
      final runFuture = h.run(script);

      // Give Python time to block on recv, then send.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      bus.send('async_ch', {'token': 'hello'});

      final result = await runFuture;
      expect(result.error, isNull);
      final msg = result.value.dartValue! as Map;
      expect(msg['token'], 'hello');
    });
  });

  // ---------------------------------------------------------------------------
  // G6-3: msg_peek
  // ---------------------------------------------------------------------------

  group('G6-3: msg_peek', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('msg_peek returns front without consuming', () async {
      bus
        ..send('peekable', 'first')
        ..send('peekable', 'second');

      final result = await h.run('''
p = msg_peek(name='peekable')
r = msg_recv(name='peekable')
[p, r]
''');

      expect(result.error, isNull);
      expect(result.value.dartValue, ['first', 'first']);
      // Queue should still have 'second'.
      expect(bus.peek('peekable'), 'second');
    });

    test('msg_peek on empty channel returns None', () async {
      final result = await h.run("msg_peek(name='empty_ch')");

      expect(result.error, isNull);
      expect(result.value.dartValue, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // G6-4: msg_close
  // ---------------------------------------------------------------------------

  group('G6-4: msg_close', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('msg_recv on closed empty channel returns None', () async {
      bus.close('done');

      final result = await h.run("msg_recv(name='done')");

      expect(result.error, isNull);
      expect(result.value.dartValue, isNull);
    });

    test('close unblocks Python waiting on recv', () async {
      const script = "msg_recv(name='drain')";
      final runFuture = h.run(script);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      bus.close('drain');

      final result = await runFuture;
      expect(result.error, isNull);
      expect(result.value.dartValue, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // G6-5: msg_stats
  // ---------------------------------------------------------------------------

  group('G6-5: msg_stats via snapshotSignal', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('snapshotSignal reflects send + recv counts', () async {
      await h.run('''
msg_send(name='stats_ch', message=1)
msg_send(name='stats_ch', message=2)
msg_recv(name='stats_ch')
''');

      final snap = bus.channel('stats_ch').snapshot;
      expect(snap.sendCount, 2);
      expect(snap.recvCount, 1);
      expect(snap.queueDepth, 1);
    });

    test('peakQueueDepth tracks historical max', () async {
      await h.run('''
msg_send(name='peak', message=1)
msg_send(name='peak', message=2)
msg_send(name='peak', message=3)
msg_recv(name='peak')
msg_recv(name='peak')
msg_recv(name='peak')
''');

      final snap = bus.channel('peak').snapshot;
      expect(snap.peakQueueDepth, 3);
      expect(snap.queueDepth, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // G6-6: Multiple channels — isolation
  // ---------------------------------------------------------------------------

  group('G6-6: multiple channels are isolated', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('messages on channel A do not appear on channel B', () async {
      await h.run('''
msg_send(name='chA', message='alpha')
msg_send(name='chB', message='beta')
''');

      expect(await bus.recv('chA'), 'alpha');
      expect(bus.peek('chB'), 'beta');
      expect(bus.peek('chA'), isNull); // A is now empty
    });
  });

  // ---------------------------------------------------------------------------
  // G6-7: High-volume throughput
  // ---------------------------------------------------------------------------

  group('G6-7: high-volume throughput', () {
    late MontyHarness h;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('1000 messages sent + received without loss', () async {
      await h.run('''
for i in range(1000):
    msg_send(name='bulk', message=i)
''');

      var received = 0;
      var sum = 0;
      while (bus.peek('bulk') != null) {
        sum += (await bus.recv('bulk'))! as int;
        received++;
      }

      expect(received, 1000);
      expect(sum, 499500); // 0+1+...+999
    });
  });

  // ---------------------------------------------------------------------------
  // G6-8: FauxUi — msg_send/recv appear in event stream
  // ---------------------------------------------------------------------------

  group('G6-8: FauxUi observes msg_send events', () {
    late MontyHarness h;
    late MessageBus bus;
    late FauxUi ui;

    setUp(() async {
      bus = MessageBus();
      h = MontyHarness(extensions: [MessageBusExtension(bus: bus)]);
      await h.setup();
      ui = FauxUi(h.runtime);
    });

    tearDown(() async {
      ui.dispose();
      await h.dispose();
    });

    test('msg_send call appears as BridgeFunctionCallStart', () async {
      await h.run("msg_send(name='x', message=1)");

      final calls = ui.eventsOf<BridgeFunctionCallStart>();
      expect(calls.map((e) => e.name), contains('msg_send'));
    });

    test('reset() clears event history between observations', () async {
      await h.run("msg_send(name='x', message=1)");
      ui.reset();
      await h.run("msg_send(name='x', message=2)");

      expect(ui.eventsOf<BridgeFunctionCallStart>(), hasLength(1));
    });
  });
} // end main
