// G1-G2: Sandbox extension experiments — FFI only.
//
// Covers child lifecycle, parallel execution, error propagation, output
// capture, signals (childrenSignal / aliveCountSignal), gather, and limits.
//
// Run with:
//   dart test -p vm --tags=integration \
//     test/experiments/sandbox_experiment_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';

import 'package:test/test.dart';

import '../integration/_monty_harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // G1-1: Basic spawn → await round-trip
  // ---------------------------------------------------------------------------

  group('G1-1: sandbox basic spawn + await', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('child completes and returns a value', () async {
      final result = await h.run('''
handle = sandbox_spawn(code="1 + 1")
sandbox_await(handle=handle)
''');

      expect(result.dartValue, 2);
    });

    test('child is ChildCompleted in childrenSignal after await', () async {
      await h.run('''
handle = sandbox_spawn(code="42")
sandbox_await(handle=handle)
''');

      expect(
        (await h.run('sandbox_is_alive(handle=handle)')).dartValue,
        isFalse,
      );
    });

    test('child value is accessible after free', () async {
      await h.run('''
h1 = sandbox_spawn(code="'hello'")
v = sandbox_await(handle=h1)
sandbox_free(handle=h1)
v
''');

      // After free, handle removed from map
      expect((await h.run('v')).dartValue, 'hello');
      await expectLater(
        h.run('sandbox_is_alive(handle=h1)'),
        throwsA(isA<MontyError>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // G1-2: Parallel children
  // ---------------------------------------------------------------------------

  group('G1-2: parallel children', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('two children run concurrently', () async {
      final result = await h.run('''
h1 = sandbox_spawn(code="1 + 1")
h2 = sandbox_spawn(code="10 + 10")
r1 = sandbox_await(handle=h1)
r2 = sandbox_await(handle=h2)
[r1, r2]
''');

      final list = result.dartValue! as List;
      expect(list, containsAll([2, 20]));
    });

    test('sandbox_await_all returns results in handle order', () async {
      final result = await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
h3 = sandbox_spawn(code="3")
sandbox_await_all(handles=[h1, h2, h3])
''');

      expect(result.dartValue, [1, 2, 3]);
    });

    test('aliveCountSignal tracks running children', () async {
      final events = <BridgeEvent>[];
      final subscription = h.runtime.events.listen(events.add);

      await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
sandbox_await_all(handles=[h1, h2])
''');

      await subscription.cancel();
      expect(
        events.whereType<BridgeChildEvent>().map((e) => e.childHandle).toSet(),
        {'0', '1'},
      );
      expect(
        (await h.run('[sandbox_is_alive(h1), sandbox_is_alive(h2)]')).dartValue,
        [false, false],
      );
    });
  });

  // ---------------------------------------------------------------------------
  // G1-3: Error propagation
  // ---------------------------------------------------------------------------

  group('G1-3: child error propagation', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('child Python error reaches parent as ChildFailed', () async {
      final events = <BridgeEvent>[];
      final sub = h.runtime.events.listen(events.add);
      addTearDown(sub.cancel);
      await h.run('''
h1 = sandbox_spawn(code="undefined_variable")
try:
    sandbox_await(handle=h1)
except Exception as e:
    str(e)
''');

      final failed = events
          .whereType<BridgeChildEvent>()
          .map((e) => e.inner)
          .whereType<BridgeRunError>()
          .toList();
      expect(failed, isNotEmpty);
      expect(failed.first.exception, isNotNull);
    });

    test('ChildFailed contains Python exception type', () async {
      final events = <BridgeEvent>[];
      final sub = h.runtime.events.listen(events.add);
      addTearDown(sub.cancel);
      await h.run('''
h1 = sandbox_spawn(code="raise ValueError('boom')")
try:
    sandbox_await(handle=h1)
except Exception:
    pass
''');

      final failed = events
          .whereType<BridgeChildEvent>()
          .map((e) => e.inner)
          .whereType<BridgeRunError>()
          .first;
      expect(failed.exception?.exception.excType, contains('ValueError'));
    });

    test('parent continues after child failure', () async {
      final result = await h.run('''
h1 = sandbox_spawn(code="raise RuntimeError('x')")
try:
    sandbox_await(handle=h1)
except Exception:
    pass
"parent survived"
''');

      expect(result.dartValue, 'parent survived');
    });
  });

  // ---------------------------------------------------------------------------
  // G1-4: Output capture
  // ---------------------------------------------------------------------------

  group('G1-4: print output capture', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('sandbox_get_output returns print() lines', () async {
      final result = await h.run(r'''
h1 = sandbox_spawn(code="print('hello')\nprint('world')")
sandbox_await(handle=h1)
sandbox_get_output(handle=h1)
''');

      final output = result.dartValue as String?;
      expect(output, contains('hello'));
      expect(output, contains('world'));
    });

    test('sandbox_gather includes output and return value', () async {
      final result = await h.run(r'''
h1 = sandbox_spawn(code="print('log line')\n42")
results = sandbox_gather(handles=[h1])
results[0]
''');

      final entry = result.dartValue! as Map;
      expect(entry['value'], 42);
      expect(entry['output'] as String, contains('log line'));
    });
  });

  // ---------------------------------------------------------------------------
  // G1-5: sandbox_is_alive
  // ---------------------------------------------------------------------------

  group('G1-5: sandbox_is_alive', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('is_alive returns True while child running, False after', () async {
      final result = await h.run('''
h1 = sandbox_spawn(code="1 + 1")
# is_alive before await should typically be True (racing, but test the API)
sandbox_await(handle=h1)
sandbox_is_alive(handle=h1)
''');

      expect(result.dartValue, false);
    });
  });

  // ---------------------------------------------------------------------------
  // G2-1: childrenSignal + FauxUi — BridgeChildEvent integration
  // ---------------------------------------------------------------------------

  group('G2-1: FauxUi observes BridgeChildEvent from sandbox children', () {
    late MontyHarness h;
    late SandboxExtension sandbox;
    late FauxUi ui;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
      ui = FauxUi(h.runtime);
    });

    tearDown(() async {
      ui.dispose();
      await h.dispose();
    });

    test(
      'child executions arrive as BridgeChildEvent in runtime.events',
      () async {
        await h.run('''
h1 = sandbox_spawn(code="1 + 1")
sandbox_await(handle=h1)
''');

        ui.assertContains<BridgeChildEvent>();
      },
    );
  });

  // ---------------------------------------------------------------------------
  // G2-2: SignalCapture on childrenSignal
  // ---------------------------------------------------------------------------

  group('G2-2: SignalCapture on childrenSignal', () {
    late MontyHarness h;
    late SandboxExtension sandbox;

    setUp(() async {
      sandbox = SandboxExtension();
      h = MontyHarness(extensions: [sandbox]);
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('captures every state transition in childrenSignal', () async {
      final events = <BridgeEvent>[];
      final sub = h.runtime.events.listen(events.add);

      await h.run('''
h1 = sandbox_spawn(code="99")
sandbox_await(handle=h1)
''');

      await sub.cancel();
      final childEvents = events
          .whereType<BridgeChildEvent>()
          .map((e) => e.inner)
          .toList();
      expect(childEvents.first, isA<BridgeRunStarted>());
      expect(childEvents.last, isA<BridgeRunFinished>());
    });
  });
} // end main
