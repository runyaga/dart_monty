import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

void main() {
  late MessageBusPlugin plugin;

  setUp(() {
    plugin = MessageBusPlugin();
  });

  HostFunctionHandler findHandler(String name) {
    return plugin.functions.firstWhere((f) => f.schema.name == name).handler;
  }

  group('metadata', () {
    test('namespace is msg', () {
      expect(plugin.namespace, 'msg');
    });

    test('provides 5 host functions', () {
      expect(plugin.functions, hasLength(5));
    });

    test('all function names start with msg_', () {
      for (final fn in plugin.functions) {
        expect(fn.schema.name, startsWith('msg_'));
      }
    });

    test('systemPromptContext is non-null', () {
      expect(plugin.systemPromptContext, isNotNull);
    });

    test('createChildInstance shares bus', () {
      final child = plugin.createChildInstance()! as MessageBusPlugin;
      expect(child, isNot(same(plugin)));
      expect(child.bus, same(plugin.bus));
    });
  });

  group('msg_send / msg_recv', () {
    test('send then recv returns FIFO order', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      await send({'name': 'ch', 'message': 'first'});
      await send({'name': 'ch', 'message': 'second'});

      expect(await recv({'name': 'ch'}), 'first');
      expect(await recv({'name': 'ch'}), 'second');
    });

    test('recv before send blocks until send', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      final future = recv({'name': 'ch'});
      // Not yet resolved.
      await Future<void>.delayed(Duration.zero);
      await send({'name': 'ch', 'message': 42});

      expect(await future, 42);
    });

    test('multiple producers single consumer', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      await send({'name': 'ch', 'message': 'a'});
      await send({'name': 'ch', 'message': 'b'});
      await send({'name': 'ch', 'message': 'c'});

      expect(await recv({'name': 'ch'}), 'a');
      expect(await recv({'name': 'ch'}), 'b');
      expect(await recv({'name': 'ch'}), 'c');
    });

    test('single producer multiple consumers', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      final f1 = recv({'name': 'ch'});
      final f2 = recv({'name': 'ch'});

      await send({'name': 'ch', 'message': 'x'});
      await send({'name': 'ch', 'message': 'y'});

      expect(await f1, 'x');
      expect(await f2, 'y');
    });
  });

  group('timeout', () {
    test('recv with timeout succeeds if message available', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      await send({'name': 'ch', 'message': 'fast'});
      final result = await recv({'name': 'ch', 'timeout_ms': 5000});
      expect(result, 'fast');
    });

    test('recv with timeout throws StateError on expiry', () async {
      final recv = findHandler('msg_recv');
      expect(() => recv({'name': 'empty', 'timeout_ms': 1}), throwsStateError);
    });

    test('timed-out recv does not consume later messages', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');

      // Timeout waiting on empty channel.
      await expectLater(
        () => recv({'name': 'ch', 'timeout_ms': 1}),
        throwsStateError,
      );

      // Now send and recv normally — the timed-out waiter must not steal it.
      await send({'name': 'ch', 'message': 'after'});
      expect(await recv({'name': 'ch'}), 'after');
    });
  });

  group('msg_peek', () {
    test('peek returns null on empty', () async {
      final peek = findHandler('msg_peek');
      expect(await peek({'name': 'empty'}), isNull);
    });

    test('peek returns front without removing', () async {
      final send = findHandler('msg_send');
      final peek = findHandler('msg_peek');
      final recv = findHandler('msg_recv');

      await send({'name': 'ch', 'message': 'head'});
      expect(await peek({'name': 'ch'}), 'head');
      // Still there.
      expect(await recv({'name': 'ch'}), 'head');
    });

    test('peek on closed empty returns null', () async {
      final close = findHandler('msg_close');
      final peek = findHandler('msg_peek');

      await close({'name': 'ch'});
      expect(await peek({'name': 'ch'}), isNull);
    });
  });

  group('msg_close', () {
    test('close unblocks pending receivers with null', () async {
      final recv = findHandler('msg_recv');
      final close = findHandler('msg_close');

      final future = recv({'name': 'ch'});
      await Future<void>.delayed(Duration.zero);
      await close({'name': 'ch'});

      expect(await future, isNull);
    });

    test('send after close throws StateError', () async {
      final send = findHandler('msg_send');
      final close = findHandler('msg_close');

      await close({'name': 'ch'});
      expect(() => send({'name': 'ch', 'message': 'late'}), throwsStateError);
    });

    test('recv drains remaining messages before returning null', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');
      final close = findHandler('msg_close');

      await send({'name': 'ch', 'message': 'a'});
      await send({'name': 'ch', 'message': 'b'});
      await close({'name': 'ch'});

      expect(await recv({'name': 'ch'}), 'a');
      expect(await recv({'name': 'ch'}), 'b');
      expect(await recv({'name': 'ch'}), isNull);
    });

    test('close is idempotent', () async {
      final close = findHandler('msg_close');

      await close({'name': 'ch'});
      await close({'name': 'ch'}); // no throw
    });
  });

  group('msg_stats', () {
    test('tracks send/recv counts', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');
      final stats = findHandler('msg_stats');

      await send({'name': 'ch', 'message': 1});
      await send({'name': 'ch', 'message': 2});
      await recv({'name': 'ch'});

      final s = (await stats({'name': 'ch'}))! as Map<String, Object?>;
      expect(s['send_count'], 2);
      expect(s['recv_count'], 1);
    });

    test('tracks peak queue depth', () async {
      final send = findHandler('msg_send');
      final recv = findHandler('msg_recv');
      final stats = findHandler('msg_stats');

      await send({'name': 'ch', 'message': 1});
      await send({'name': 'ch', 'message': 2});
      await send({'name': 'ch', 'message': 3});
      await recv({'name': 'ch'});
      await recv({'name': 'ch'});

      final s = (await stats({'name': 'ch'}))! as Map<String, Object?>;
      expect(s['peak_queue_depth'], 3);
      expect(s['queue_depth'], 1);
    });
  });

  group('disposal', () {
    test('onDispose completes pending receivers with StateError', () async {
      final recv = findHandler('msg_recv');

      final future = recv({'name': 'ch'});
      await Future<void>.delayed(Duration.zero);

      await plugin.onDispose();

      expect(future, throwsStateError);
    });

    test('sibling plugin instance still works after one disposed', () async {
      final child = plugin.createChildInstance()! as MessageBusPlugin;
      final childSend = child.functions.firstWhere(
        (f) => f.schema.name == 'msg_send',
      );

      // Dispose parent.
      await plugin.onDispose();

      // Child can still send — bus is still alive.
      await childSend.handler({'name': 'ch', 'message': 'from_child'});

      // New plugin on same bus can receive.
      final fresh = MessageBusPlugin(bus: child.bus);
      final freshRecv = fresh.functions.firstWhere(
        (f) => f.schema.name == 'msg_recv',
      );
      expect(await freshRecv.handler({'name': 'ch'}), 'from_child');
    });
  });

  group('MessageChannel direct Dart usage', () {
    test('starts with empty snapshot', () {
      final ch = MessageChannel();
      expect(ch.snapshot, ChannelSnapshot.empty);
      expect(ch.isClosed, false);
    });

    test('send increments sendCount', () {
      final ch = MessageChannel()..send('a');
      expect(ch.snapshot.sendCount, 1);
      expect(ch.snapshot.queueDepth, 1);
    });

    test('send then recv decrements queueDepth', () {
      final ch = MessageChannel()..send('a');
      unawaited(ch.recv());
      expect(ch.snapshot.queueDepth, 0);
      expect(ch.snapshot.recvCount, 1);
    });

    test(
      'direct send-to-waiter increments both counts without queue',
      () async {
        final ch = MessageChannel();
        final future = ch.recv();
        ch.send('x');
        await future;
        expect(ch.snapshot.sendCount, 1);
        expect(ch.snapshot.recvCount, 1);
        expect(ch.snapshot.queueDepth, 0);
      },
    );

    test('tracks peak queue depth', () {
      final ch = MessageChannel()
        ..send(1)
        ..send(2)
        ..send(3);
      unawaited(ch.recv());
      expect(ch.snapshot.peakQueueDepth, 3);
      expect(ch.snapshot.queueDepth, 2);
    });

    test('close sets isClosed and resolves waiters with null', () async {
      final ch = MessageChannel();
      final future = ch.recv();
      ch.close();
      expect(await future, isNull);
      expect(ch.snapshot.isClosed, true);
    });

    test('snapshotSignal fires on send', () {
      final ch = MessageChannel();
      final observed = <ChannelSnapshot>[];
      final dispose = effect(() => observed.add(ch.snapshotSignal.value));
      addTearDown(dispose);

      ch.send('msg');

      expect(observed.length, 2); // initial + after send
      expect(observed.last.sendCount, 1);
    });

    test('snapshotSignal fires on recv', () async {
      final ch = MessageChannel()..send('a');
      final observed = <ChannelSnapshot>[];
      final dispose = effect(() => observed.add(ch.snapshotSignal.value));
      addTearDown(dispose);

      await ch.recv();

      expect(observed.last.recvCount, 1);
      expect(observed.last.queueDepth, 0);
    });

    test('snapshotSignal fires on close', () {
      final ch = MessageChannel();
      final observed = <ChannelSnapshot>[];
      final dispose = effect(() => observed.add(ch.snapshotSignal.value));
      addTearDown(dispose);

      ch.close();

      expect(observed.last.isClosed, true);
    });
  });

  group('MessageBus signals', () {
    test('channelsSignal is empty before any channel access', () {
      final bus = MessageBus();
      expect(bus.channelsSignal.value, isEmpty);
    });

    test('channelsSignal updates when a new channel is auto-created', () {
      final bus = MessageBus();
      final observed = <Map<String, MessageChannel>>[];
      final dispose = effect(
        () => observed.add(Map.from(bus.channelsSignal.value)),
      );
      addTearDown(dispose);

      bus.channel('tasks');

      expect(observed.length, 2); // initial + after creation
      expect(observed.last.keys, contains('tasks'));
    });

    test(
      'channelsSignal does not fire for channelOrNull on missing channel',
      () {
        final bus = MessageBus();
        final observed = <int>[];
        final dispose = effect(
          () => observed.add(bus.channelsSignal.value.length),
        );
        addTearDown(dispose);

        bus.channelOrNull('nonexistent');

        expect(observed, [0]); // only the initial fire
      },
    );

    test('accessing same channel twice does not re-fire channelsSignal', () {
      // Pre-create 'x' before subscribing so the effect starts at length 1.
      final bus = MessageBus()..channel('x');
      final observed = <int>[];
      final dispose = effect(
        () => observed.add(bus.channelsSignal.value.length),
      );
      addTearDown(dispose);

      bus.channel('x'); // access existing — no new creation event

      expect(observed, [1]); // only the initial fire
    });

    test('bus.send auto-creates channel and updates channelsSignal', () {
      final bus = MessageBus();
      final observed = <Map<String, MessageChannel>>[];
      final dispose = effect(
        () => observed.add(Map.from(bus.channelsSignal.value)),
      );
      addTearDown(dispose);

      bus.send('work', 42);

      expect(observed.last.keys, contains('work'));
    });

    test('channel snapshotSignal updates flow through shared bus', () async {
      final bus = MessageBus();

      // Simulate parent plugin and child plugin sharing the same bus.
      final parentCh = bus.channel('shared');
      final childCh = bus.channel('shared'); // same object
      expect(identical(parentCh, childCh), isTrue);

      final observed = <ChannelSnapshot>[];
      final dispose = effect(
        () => observed.add(parentCh.snapshotSignal.value),
      );
      addTearDown(dispose);

      // Child sends; parent's signal updates because it's the same channel.
      childCh.send('from_child');
      expect(observed.last.sendCount, 1);
    });
  });

  group('parent↔child integration', () {
    test('parent sends, child receives via shared bus', () async {
      final child = plugin.createChildInstance()! as MessageBusPlugin;
      final parentSend = findHandler('msg_send');
      final childRecv = child.functions.firstWhere(
        (f) => f.schema.name == 'msg_recv',
      );

      await parentSend({
        'name': 'task',
        'message': {'file': 'data.txt'},
      });
      final msg = await childRecv.handler({'name': 'task'});
      expect(msg, {'file': 'data.txt'});
    });

    test('child sends, parent receives via shared bus', () async {
      final child = plugin.createChildInstance()! as MessageBusPlugin;
      final childSend = child.functions.firstWhere(
        (f) => f.schema.name == 'msg_send',
      );
      final parentRecv = findHandler('msg_recv');

      await childSend.handler({
        'name': 'result',
        'message': {'count': 42, 'status': 'done'},
      });
      final msg = await parentRecv({'name': 'result'});
      expect(msg, {'count': 42, 'status': 'done'});
    });
  });
}
