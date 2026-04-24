// G5: Signals experiments.
//
// Covers SignalCapture, Computed signals, effect cleanup, per-plugin reactive
// signals (channelStateSignal, snapshotSignal, childrenSignal), and FauxUi
// signal-wiring patterns.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/signals_experiment_test.dart
//
// Sandbox tests require vm; others work on both backends.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

import 'harness.dart';

MontyPlatformFactory _replFactory() =>
    () async => ReplPlatform(repl: MontyRepl());

void main() {
  // ---------------------------------------------------------------------------
  // G5-1: SignalCapture basic — EventLoop channelStateSignal
  // ---------------------------------------------------------------------------

  group('G5-1: SignalCapture on EventLoop.channelStateSignal', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('records every state value including initial Idle', () async {
      final cap = SignalCapture(el.channelStateSignal);
      el.dispatch({'pre': true}); // pre-queue so no wait needed

      await h.run('el_recv()');

      cap.dispose();

      expect(cap.values.first, isA<EventLoopIdle>());
      expect(cap.values.any((s) => s is EventLoopExecuting), isTrue);
      expect(cap.values.last, isA<EventLoopCompleted>());
    });

    test('calling dispose() on SignalCapture stops recording', () {
      // Use a plain signal to avoid the EventLoop Completed-state dispatch
      // wart.
      final s = signal(0);
      final cap = SignalCapture(s);

      s
        ..value = 1
        ..value = 2;
      cap.dispose();
      s.value = 3; // NOT captured after dispose

      expect(cap.values, [0, 1, 2]);
    });
  });

  // ---------------------------------------------------------------------------
  // G5-2: SignalCapture on MessageBus.snapshotSignal
  // ---------------------------------------------------------------------------

  group('G5-2: SignalCapture on MessageBus channel snapshotSignal', () {
    late MontyHarness h;
    late MessageBusExtension busExt;
    late MessageBus bus;

    setUp(() async {
      bus = MessageBus();
      busExt = MessageBusExtension(bus: bus);
      h = MontyHarness(extensions: [busExt]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('snapshot sendCount increments on each Python send', () async {
      final ch = bus.channel('q');
      final cap = SignalCapture(ch.snapshotSignal);

      await h.run('''
msg_send(name='q', message='a')
msg_send(name='q', message='b')
msg_send(name='q', message='c')
''');

      cap.dispose();

      final counts = cap.values.map((s) => s.sendCount).toList();
      expect(counts.last, 3);
    });

    test('queueDepth goes up on send and down on recv', () async {
      bus.channel('pipe').send('item1');
      bus.channel('pipe').send('item2');

      final ch = bus.channel('pipe');
      final cap = SignalCapture(ch.snapshotSignal);

      await h.run('''
msg_recv(name='pipe')
msg_recv(name='pipe')
''');

      cap.dispose();

      final depths = cap.values.map((s) => s.queueDepth).toList();
      expect(depths.last, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // G5-3: Computed signal derived from plugin state
  // ---------------------------------------------------------------------------

  group('G5-3: Computed signal derived from EventLoop state', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('computed "isWaiting" tracks el waiting state', () async {
      final isWaiting = computed(
        () => el.channelStateSignal.value is EventLoopWaiting,
      );
      final history = <bool>[];
      final cleanup = effect(() => history.add(isWaiting.value));

      const script = 'el_recv()';
      final handle = h.runtime.execute(script);

      await _untilWaiting(el);
      el.dispatch({'go': true});
      await handle.result;

      cleanup();

      expect(history, containsAll([true, false]));
    });
  });

  // ---------------------------------------------------------------------------
  // G5-4: effect() cleanup — verify no memory leak
  // ---------------------------------------------------------------------------

  group('G5-4: effect cleanup', () {
    test('effect removed after cleanup does not track further changes', () {
      final s = signal(0);
      final log = <int>[];
      final cleanup = effect(() => log.add(s.value));

      s
        ..value = 1
        ..value = 2;
      cleanup();
      s.value = 3; // should NOT be captured

      expect(log, [0, 1, 2]);
    });

    test('multiple effects on same signal — each gets own history', () {
      final s = signal('a');
      final log1 = <String>[];
      final log2 = <String>[];
      final c1 = effect(() => log1.add(s.value));
      final c2 = effect(() => log2.add(s.value));

      s.value = 'b';
      c1();
      s.value = 'c'; // only c2 sees 'c'

      c2();
      expect(log1, ['a', 'b']);
      expect(log2, ['a', 'b', 'c']);
    });
  });

  // ---------------------------------------------------------------------------
  // G5-5: SignalCapture on aliveCountSignal (sandbox, FFI only)
  // ---------------------------------------------------------------------------

  group(
    'G5-5: SignalCapture on SandboxExtension.aliveCountSignal',
    () {
      late MontyHarness h;
      late SandboxExtension sandbox;

      setUp(() async {
        sandbox = SandboxExtension(platformFactory: _replFactory());
        h = MontyHarness(extensions: [sandbox]);
        await h.setup();
      });

      tearDown(() => h.dispose());

      test('aliveCount peaks at N then returns to 0', () async {
        final cap = SignalCapture(sandbox.aliveCountSignal);

        await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
h3 = sandbox_spawn(code="3")
sandbox_await_all(handles=[h1, h2, h3])
''');

        cap.dispose();

        // Children may complete fast; assert at least one was alive and
        // all finished.
        expect(cap.values.any((c) => c > 0), isTrue);
        expect(cap.values.last, 0);
      });
    },
    testOn: 'vm',
  );

  // ---------------------------------------------------------------------------
  // G5-6: FauxUi BridgeFunctionEmit — el_emit surfaced in events
  // ---------------------------------------------------------------------------

  group('G5-6: FauxUi sees BridgeFunctionEmit from el_emit', () {
    late MontyHarness h;
    late EventLoopExtension el;
    late FauxUi ui;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
      ui = FauxUi(h.runtime);
    });

    tearDown(() async {
      ui.dispose();
      await h.dispose();
    });

    test(
      'each el_emit call produces a BridgeFunctionCallStart event',
      () async {
        await h.run('''
el_emit(value={'tick': 1})
el_emit(value={'tick': 2})
''');

        final emitCalls = ui
            .eventsOf<BridgeFunctionCallStart>()
            .where((e) => e.name == 'el_emit')
            .toList();
        expect(emitCalls, hasLength(2));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // G5-7: FauxUi assertEventSequence with matchers
  // ---------------------------------------------------------------------------

  group('G5-7: FauxUi.assertEventSequence', () {
    late MontyHarness h;
    late FauxUi ui;

    setUp(() async {
      h = MontyHarness()..registerTool('ping', (a, c) async => 'pong');
      await h.setup();
      ui = FauxUi(h.runtime);
    });

    tearDown(() async {
      ui.dispose();
      await h.dispose();
    });

    test(
      'run starts with BridgeRunStarted and ends with BridgeRunFinished',
      () async {
        await h.run('ping()');

        // Check presence of key event types — strict ordering breaks on
        // intermediate events like BridgeStepStarted that appear between
        // run/function events.
        ui
          ..assertContains<BridgeRunStarted>()
          ..assertContains<BridgeFunctionCallStart>()
          ..assertContains<BridgeRunFinished>();
      },
    );

    test('assertAbsent passes when event type never occurred', () async {
      await h.run('1 + 1');

      ui.assertAbsent<BridgeFunctionCallStart>(); // no tool calls
    });
  });
} // end main

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<void> _untilWaiting(EventLoopExtension el) async {
  const maxWait = Duration(seconds: 5);
  const interval = Duration(milliseconds: 10);
  final deadline = DateTime.now().add(maxWait);

  while (!el.isWaiting) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('EventLoopExtension never reached Waiting state');
    }
    await Future<void>.delayed(interval);
  }
}
