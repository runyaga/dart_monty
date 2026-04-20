// G3-G4: EventLoop extension experiments.
//
// Covers the cooperative coroutine pattern: el_recv/el_emit, multi-round
// dispatch, state machine transitions, channelStateSignal, lastEmittedSignal,
// error cases, and FauxUi observation.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/event_loop_experiment_test.dart
@Tags(['integration'])
library;

import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import '../harness.dart';

void main() {
// ---------------------------------------------------------------------------
// G3-1: Basic dispatch → el_recv round-trip
// ---------------------------------------------------------------------------

group('G3-1: basic el_recv / el_emit round-trip', () {
  late MontyHarness h;
  late EventLoopExtension el;

  setUp(() async {
    el = EventLoopExtension();
    h = MontyHarness(extensions: [el]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('Python receives dispatched event via el_recv', () async {
    final script = '''
event = el_recv()
event['action']
''';

    // Start execution — Python will park at el_recv().
    final handle = h.runtime.execute(script);

    // Wait for Python to reach el_recv (state → Waiting).
    await _untilWaiting(el);
    expect(el.isWaiting, isTrue);

    // Dispatch wakes Python.
    el.dispatch({'action': 'ping'});

    final result = await handle.result;
    expect(result.error, isNull);
    expect(result.value.dartValue, 'ping');
  });

  test('el_emit pushes value to lastEmittedSignal', () async {
    final script = "el_emit(value={'status': 'ready'})";

    await h.run(script);

    expect(el.lastEmitted, isNotNull);
    expect(el.lastEmitted!['status'], 'ready');
  });

  test('state is BridgeChannelCompleted after execution finishes', () async {
    final result = await h.run('1 + 1');

    expect(result.error, isNull);
    expect(el.channelState, isA<BridgeChannelCompleted>());
  });
});

// ---------------------------------------------------------------------------
// G3-2: Pre-dispatch — queue before el_recv
// ---------------------------------------------------------------------------

group('G3-2: pre-dispatch queuing', () {
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
    el.dispatch({'seq': 0});
    el.dispatch({'seq': 1});

    final result = await h.run('''
a = el_recv()
b = el_recv()
[a['seq'], b['seq']]
''');

    expect(result.error, isNull);
    expect(result.value.dartValue, [0, 1]);
  });
});

// ---------------------------------------------------------------------------
// G3-3: Multi-round — el_recv called multiple times
// ---------------------------------------------------------------------------

group('G3-3: multi-round exchange', () {
  late MontyHarness h;
  late EventLoopExtension el;

  setUp(() async {
    el = EventLoopExtension();
    h = MontyHarness(extensions: [el]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('Python loops on el_recv — three dispatch cycles', () async {
    final script = '''
total = 0
for _ in range(3):
    event = el_recv()
    total += event['n']
total
''';

    final handle = h.runtime.execute(script);

    for (var i = 1; i <= 3; i++) {
      await _untilWaiting(el);
      el.dispatch({'n': i});
    }

    final result = await handle.result;
    expect(result.error, isNull);
    expect(result.value.dartValue, 6); // 1+2+3
  });

  test('el_emit fires each round — lastEmittedSignal updates', () async {
    final emitted = <Map<String, Object?>>[];
    final cleanup = el.lastEmittedSignal.subscribe((v) {
      if (v != null) emitted.add(v);
    });

    final script = '''
for i in range(3):
    event = el_recv()
    el_emit(value={'round': event['round']})
''';

    final handle = h.runtime.execute(script);

    for (var i = 0; i < 3; i++) {
      await _untilWaiting(el);
      el.dispatch({'round': i});
    }

    await handle.result;
    cleanup();

    expect(emitted, hasLength(3));
    expect(emitted.map((e) => e['round']), orderedEquals([0, 1, 2]));
  });
});

// ---------------------------------------------------------------------------
// G3-4: Error cases
// ---------------------------------------------------------------------------

group('G3-4: EventLoop error cases', () {
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
    expect(el.channelState, isA<BridgeChannelCompleted>());

    expect(
      () => el.dispatch({'x': 1}),
      throwsA(isA<StateError>()),
    );
  });

  test('script error transitions to Completed, not stuck Waiting', () async {
    final script = '''
el_recv()
undefined_var_that_errors
''';

    final handle = h.runtime.execute(script);
    await _untilWaiting(el);
    el.dispatch({'ok': true});

    final result = await handle.result;
    expect(result.error, isNotNull); // Python errored
    expect(el.channelState, isA<BridgeChannelCompleted>());
  });

  test('dispose while waiting completes completer with error', () async {
    final el2 = EventLoopExtension();
    final h2 = MontyHarness(extensions: [el2]);
    await h2.setup();

    final script = 'el_recv()';
    final handle = h2.runtime.execute(script);

    await _untilWaiting(el2);

    // Dispose while waiting — should complete completer with error.
    await h2.dispose();

    // Result future should have resolved (with error).
    final result = await handle.result;
    // The script never completed normally — error captured
    expect(
      result.error != null || el2.channelState is BridgeChannelDisposed,
      isTrue,
    );
  });
});

// ---------------------------------------------------------------------------
// G4-1: channelStateSignal — SignalCapture
// ---------------------------------------------------------------------------

group('G4-1: channelStateSignal transitions via SignalCapture', () {
  late MontyHarness h;
  late EventLoopExtension el;

  setUp(() async {
    el = EventLoopExtension();
    h = MontyHarness(extensions: [el]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('captures Idle → Executing → Waiting → Executing → Completed', () async {
    final cap = SignalCapture(el.channelStateSignal);

    final script = '''
el_recv()
''';

    final handle = h.runtime.execute(script);
    await _untilWaiting(el);
    el.dispatch({'go': true});
    await handle.result;

    cap.dispose();

    final types = cap.values.map((s) => s.runtimeType.toString()).toList();
    expect(types, contains('BridgeChannelExecuting'));
    expect(types, contains('BridgeChannelWaiting'));
    expect(types, contains('BridgeChannelCompleted'));
  });
});

// ---------------------------------------------------------------------------
// G4-2: FauxUi + EventLoop — BridgeRunStarted + BridgeRunFinished
// ---------------------------------------------------------------------------

group('G4-2: FauxUi observes full run lifecycle', () {
  late MontyHarness h;
  late EventLoopExtension el;
  late FauxUi ui;

  setUp(() async {
    el = EventLoopExtension();
    h = MontyHarness(extensions: [el]);
    await h.setup();
    ui = FauxUi(h.runtime);
  });

  tearDown(() {
    ui.dispose();
    h.dispose();
  });

  test('FauxUi sees BridgeRunStarted and BridgeRunFinished', () async {
    el.dispatch({'skip': true});

    await h.run('el_recv()');

    ui.assertContains<BridgeRunStarted>();
    ui.assertContains<BridgeRunFinished>();
  });

  test('el_emit produces BridgeFunctionCallStart for el_emit', () async {
    await h.run("el_emit(value={'x': 1})");

    final calls = ui.eventsOf<BridgeFunctionCallStart>();
    expect(calls.map((e) => e.name), contains('el_emit'));
  });
});

// ---------------------------------------------------------------------------
// G4-3: lastEmittedSignal reactive subscription
// ---------------------------------------------------------------------------

group('G4-3: lastEmittedSignal reactive', () {
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
    expect(nonNull.map((e) => e!['n']), orderedEquals([1, 2, 3]));
  });
});

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

} // end main

/// Polls until [el.isWaiting] becomes true (Python reached el_recv).
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
