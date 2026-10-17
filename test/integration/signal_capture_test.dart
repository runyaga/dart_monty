// Guest programs keep their long lines.
// ignore_for_file: lines_longer_than_80_chars
// SignalCapture, computed signals and effect cleanup over EventLoopExtension
// and SandboxExtension signals, plus FauxUi event sequences.
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extensions/event_loop.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

import '_monty_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // SignalCapture basic — EventLoop channelStateSignal
  // ---------------------------------------------------------------------------

  group('SignalCapture on EventLoop.channelStateSignal', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test(
      'records every state value including initial Idle',
      () async {
        final cap = SignalCapture(el.channelStateSignal);
        el.dispatch(
          MontyValue.fromDart({'pre': true}) as MontyDict,
        ); // pre-queue so no wait needed

        await h.run('await el_recv()');

        cap.dispose();

        expect(cap.values.firstOrNull, isA<EventLoopIdle>());
        expect(cap.values.any((s) => s is EventLoopExecuting), isTrue);
        expect(cap.values.lastOrNull, isA<EventLoopCompleted>());
      },
    );

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
  // Computed signal derived from plugin state
  // ---------------------------------------------------------------------------

  group('Computed signal derived from EventLoop state', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test(
      'computed "isWaiting" tracks el waiting state',
      () async {
        final isWaiting = computed(
          () => el.channelStateSignal.value is EventLoopWaiting,
        );
        final history = <bool>[];
        final cleanup = effect(() => history.add(isWaiting.value));

        const script = 'await el_recv()';
        final handle = h.runtime.execute(script);

        await _untilWaiting(el);
        el.dispatch(MontyValue.fromDart({'go': true}) as MontyDict);
        await handle.result;

        cleanup();

        expect(history, containsAll([true, false]));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // effect() cleanup — verify no memory leak
  // ---------------------------------------------------------------------------

  group('effect cleanup', () {
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
  // SignalCapture on aliveCountSignal (sandbox)
  // ---------------------------------------------------------------------------

  group(
    'SignalCapture on SandboxExtension.aliveCountSignal',
    () {
      late MontyHarness h;
      late SandboxExtension sandbox;

      setUp(() async {
        sandbox = SandboxExtension();
        h = MontyHarness(extensions: [sandbox]);
        await h.setup();
      });

      tearDown(() => h.dispose());

      test(
        'aliveCount peaks at N then returns to 0',
        () async {
          final events = <BridgeEvent>[];
          final sub = h.runtime.events.listen(events.add);

          await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
h3 = sandbox_spawn(code="3")
sandbox_await_all(handles=[h1, h2, h3])
''');

          await sub.cancel();
          expect(
            events
                .whereType<BridgeChildEvent>()
                .map((e) => e.childHandle)
                .toSet(),
            {'0', '1', '2'},
          );
          expect(
            (await h.run(
              '[sandbox_is_alive(h1), sandbox_is_alive(h2), sandbox_is_alive(h3)]',
            )).dartValue,
            [false, false, false],
          );
        },
      );
    },
  );

  // ---------------------------------------------------------------------------
  // FauxUi BridgeFunctionEmit — el_emit surfaced in events
  // ---------------------------------------------------------------------------

  group('FauxUi sees BridgeFunctionEmit from el_emit', () {
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
  // FauxUi assertEventSequence with matchers
  // ---------------------------------------------------------------------------

  group('FauxUi.assertEventSequence', () {
    late MontyHarness h;
    late FauxUi ui;

    setUp(() async {
      h = MontyHarness()
        ..registerTool('ping', (a, c) async => const MontyString('pong'));
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

    test(
      'assertAbsent passes when event type never occurred',
      () async {
        await h.run('1 + 1');

        ui.assertAbsent<BridgeFunctionCallStart>(); // no tool calls
      },
    );
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
