// EventLoop extension experiments.
//
// Covers the cooperative coroutine pattern: el_recv/el_emit, multi-round
// dispatch, state machine transitions, channelStateSignal, lastEmittedSignal,
// error cases, and FauxUi observation.
//
// Run with:
//   dart test --tags=integration \
//     test/integration/event_loop_extension_test.dart
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extensions/event_loop.dart';
import 'package:test/test.dart';

import '_monty_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Basic el_recv / el_emit round-trip.
  // ---------------------------------------------------------------------------

  group('basic el_recv / el_emit round-trip', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python receives dispatched event via el_recv', () async {
      const script = '''
event = await el_recv()
event['action']
''';

      // Start execution — Python will park at el_recv().
      final handle = h.runtime.execute(script);

      // Wait for Python to reach el_recv (state → Waiting).
      await _untilWaiting(el);
      expect(el.isWaiting, isTrue);

      // Dispatch wakes Python.
      el.dispatch(MontyValue.fromDart({'action': 'ping'}) as MontyDict);

      final result = await handle.result;
      expect(result.dartValue, 'ping');
    });

    test('el_emit pushes value to lastEmittedSignal', () async {
      const script = "el_emit(value={'status': 'ready'})";

      await h.run(script);

      expect(el.lastEmitted, isNotNull);
      expect((el.lastEmitted!.dartValue! as Map)['status'], 'ready');
    });

    test('state is EventLoopCompleted after execution finishes', () async {
      await h.run('1 + 1');

      expect(el.channelState, isA<EventLoopCompleted>());
    });
  });

  // ---------------------------------------------------------------------------
  // Pre-dispatch queuing.
  // ---------------------------------------------------------------------------

  group('pre-dispatch queuing', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('events dispatched before el_recv are returned immediately', () async {
      // Dispatch before Python runs — goes to queue.
      el
        ..dispatch(MontyValue.fromDart({'seq': 0}) as MontyDict)
        ..dispatch(MontyValue.fromDart({'seq': 1}) as MontyDict);

      final result = await h.run('''
a = await el_recv()
b = await el_recv()
[a['seq'], b['seq']]
''');

      expect(result.dartValue, [0, 1]);
    });
  });

  // ---------------------------------------------------------------------------
  // Multi-round exchange.
  // ---------------------------------------------------------------------------

  group('multi-round exchange', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('Python loops on el_recv — three dispatch cycles', () async {
      const script = '''
total = 0
for _ in range(3):
    event = await el_recv()
    total += event['n']
total
''';

      final handle = h.runtime.execute(script);

      for (var i = 1; i <= 3; i++) {
        await _untilWaiting(el);
        el.dispatch(MontyValue.fromDart({'n': i}) as MontyDict);
      }

      final result = await handle.result;
      expect(result.dartValue, 6); // 1+2+3
    });

    test('el_emit fires each round — lastEmittedSignal updates', () async {
      final emitted = <Map<String, Object?>>[];
      final cleanup = el.lastEmittedSignal.subscribe((v) {
        if (v != null) {
          emitted.add(Map.from(v.dartValue! as Map));
        }
      });

      const script = '''
for i in range(3):
    event = await el_recv()
    el_emit(value={'round': event['round']})
''';

      final handle = h.runtime.execute(script);

      for (var i = 0; i < 3; i++) {
        await _untilWaiting(el);
        el.dispatch(MontyValue.fromDart({'round': i}) as MontyDict);
      }

      await handle.result;
      cleanup();

      expect(emitted, hasLength(3));
      expect(emitted.map((e) => e['round']), orderedEquals([0, 1, 2]));
    });
  });

  // ---------------------------------------------------------------------------
  // EventLoop error cases.
  // ---------------------------------------------------------------------------

  group('EventLoop error cases', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('dispatch on completed state throws StateError', () async {
      await h.run('1 + 1');
      expect(el.channelState, isA<EventLoopCompleted>());

      expect(
        () => el.dispatch(MontyValue.fromDart({'x': 1}) as MontyDict),
        throwsA(isA<StateError>()),
      );
    });

    test('script error transitions to Completed, not stuck Waiting', () async {
      const script = '''
await el_recv()
undefined_var_that_errors
''';

      final handle = h.runtime.execute(script);
      await _untilWaiting(el);
      el.dispatch(MontyValue.fromDart({'ok': true}) as MontyDict);

      // Python errored.
      await expectLater(handle.result, throwsA(isA<MontyError>()));
      expect(el.channelState, isA<EventLoopCompleted>());
    });

    test('dispose while waiting completes completer with error', () async {
      final el2 = EventLoopExtension();
      final h2 = MontyHarness(extensions: [el2]);
      await h2.setup();

      const script = 'await el_recv()';
      final handle = h2.runtime.execute(script);

      await _untilWaiting(el2);

      // Dispose while waiting closes the running session: the pending host
      // call fails at once, so the result fails with StateError.
      final outcome = handle.result.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await h2.dispose();

      expect(await outcome, isA<StateError>());
      expect(el2.channelState, isA<EventLoopDisposed>());
    });
  });

  // ---------------------------------------------------------------------------
  // channelStateSignal transitions via SignalCapture.
  // ---------------------------------------------------------------------------

  group('channelStateSignal transitions via SignalCapture', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test(
      'captures Idle → Executing → Waiting → Executing → Completed',
      () async {
        final cap = SignalCapture(el.channelStateSignal);

        const script = '''
await el_recv()
''';

        final handle = h.runtime.execute(script);
        await _untilWaiting(el);
        el.dispatch(MontyValue.fromDart({'go': true}) as MontyDict);
        await handle.result;

        cap.dispose();

        final types = cap.values.map((s) => s.runtimeType.toString()).toList();
        expect(types, contains('EventLoopExecuting'));
        expect(types, contains('EventLoopWaiting'));
        expect(types, contains('EventLoopCompleted'));
      },
    );
  });

  // ---------------------------------------------------------------------------
  // FauxUi observes the full run lifecycle.
  // ---------------------------------------------------------------------------

  group('FauxUi observes full run lifecycle', () {
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

    test('FauxUi sees BridgeRunStarted and BridgeRunFinished', () async {
      el.dispatch(MontyValue.fromDart({'skip': true}) as MontyDict);

      await h.run('await el_recv()');

      ui
        ..assertContains<BridgeRunStarted>()
        ..assertContains<BridgeRunFinished>();
    });

    test('el_emit produces BridgeFunctionCallStart for el_emit', () async {
      await h.run("el_emit(value={'x': 1})");

      final calls = ui.eventsOf<BridgeFunctionCallStart>();
      expect(calls.map((e) => e.name), contains('el_emit'));
    });
  });

  // ---------------------------------------------------------------------------
  // lastEmittedSignal reactive subscription.
  // ---------------------------------------------------------------------------

  group('lastEmittedSignal reactive', () {
    late MontyHarness h;
    late EventLoopExtension el;

    setUp(() async {
      el = EventLoopExtension();
      h = MontyHarness(extensions: [el]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('SignalCapture on lastEmittedSignal records every emission', () async {
      final cap = SignalCapture(el.lastEmittedSignal);

      await h.run('''
el_emit(value={'n': 1})
el_emit(value={'n': 2})
el_emit(value={'n': 3})
''');

      cap.dispose();
      // cap.values[0] is null (initial), then 3 updates.
      final nonNull = cap.values.where((v) => v != null).toList();
      expect(nonNull, hasLength(3));
      expect(
        nonNull.map((e) => (e!.dartValue! as Map)['n']),
        orderedEquals([1, 2, 3]),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
} // end main

/// Polls until `el.isWaiting` becomes true (Python reached el_recv).
Future<void> _untilWaiting(EventLoopExtension el) async {
  const maxWait = Duration(seconds: 5);
  const interval = Duration(milliseconds: 10);
  final deadline = DateTime.now().add(maxWait);

  while (!el.isWaiting) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('EventLoopExtension never reached Waiting state');
    }
    await Future<void>.delayed(interval);
  }
}
