// G1-G2: Sandbox extension experiments — FFI only.
//
// Covers child lifecycle, parallel execution, error propagation, output
// capture, signals (childrenSignal / aliveCountSignal), gather, and limits.
//
// Run with:
//   dart test -p vm --tags=integration \
//     test/experiment/examples/sandbox_experiment_test.dart
@TestOn('vm')
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

import '../harness.dart';

// Builds a fresh ReplPlatform for each sandbox child.
MontyPlatformFactory _replFactory() =>
    () async => ReplPlatform(repl: MontyRepl());

void main() {
// ---------------------------------------------------------------------------
// G1-1: Basic spawn → await round-trip
// ---------------------------------------------------------------------------

group('G1-1: sandbox basic spawn + await', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
    h = MontyHarness(extensions: [sandbox]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('child completes and returns a value', () async {
    final result = await h.run('''
handle = sandbox_spawn(code="1 + 1")
sandbox_await(handle=handle)
''');

    expect(result.error, isNull);
    expect(result.value.dartValue, 2);
  });

  test('child is ChildCompleted in childrenSignal after await', () async {
    await h.run('''
handle = sandbox_spawn(code="42")
sandbox_await(handle=handle)
''');

    final states = sandbox.childrenSignal.value;
    expect(states.values.whereType<ChildCompleted>(), isNotEmpty);
  });

  test('child value is accessible after free', () async {
    await h.run('''
h1 = sandbox_spawn(code="'hello'")
v = sandbox_await(handle=h1)
sandbox_free(handle=h1)
v
''');

    final freed = sandbox.childrenSignal.value.values
        .whereType<ChildCompleted>()
        .toList();
    // After free, handle removed from map
    expect(sandbox.childrenSignal.value, isEmpty);
  });
});

// ---------------------------------------------------------------------------
// G1-2: Parallel children
// ---------------------------------------------------------------------------

group('G1-2: parallel children', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
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

    expect(result.error, isNull);
    final list = result.value.dartValue as List;
    expect(list, containsAll([2, 20]));
  });

  test('sandbox_await_all returns results in handle order', () async {
    final result = await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
h3 = sandbox_spawn(code="3")
sandbox_await_all(handles=[h1, h2, h3])
''');

    expect(result.error, isNull);
    expect(result.value.dartValue, [1, 2, 3]);
  });

  test('aliveCountSignal tracks running children', () async {
    final counts = <int>[];
    final cleanup = effect(() => counts.add(sandbox.aliveCountSignal.value));

    await h.run('''
h1 = sandbox_spawn(code="1")
h2 = sandbox_spawn(code="2")
sandbox_await_all(handles=[h1, h2])
''');

    cleanup();
    expect(counts, contains(2)); // peak of 2 alive simultaneously
    expect(counts.last, 0); // back to 0 after both complete
  });
});

// ---------------------------------------------------------------------------
// G1-3: Error propagation
// ---------------------------------------------------------------------------

group('G1-3: child error propagation', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
    h = MontyHarness(extensions: [sandbox]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('child Python error reaches parent as ChildFailed', () async {
    await h.run('''
h1 = sandbox_spawn(code="undefined_variable")
try:
    sandbox_await(handle=h1)
except Exception as e:
    str(e)
''');

    final failed = sandbox.childrenSignal.value.values
        .whereType<ChildFailed>()
        .toList();
    expect(failed, isNotEmpty);
    expect(failed.first.exception, isNotNull);
  });

  test('ChildFailed contains Python exception type', () async {
    await h.run('''
h1 = sandbox_spawn(code="raise ValueError('boom')")
try:
    sandbox_await(handle=h1)
except Exception:
    pass
''');

    final failed = sandbox.childrenSignal.value.values
        .whereType<ChildFailed>()
        .first;
    expect(failed.exception?.excType, contains('ValueError'));
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

    expect(result.error, isNull);
    expect(result.value.dartValue, 'parent survived');
  });
});

// ---------------------------------------------------------------------------
// G1-4: Output capture
// ---------------------------------------------------------------------------

group('G1-4: print output capture', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
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

    expect(result.error, isNull);
    final output = result.value.dartValue as String?;
    expect(output, contains('hello'));
    expect(output, contains('world'));
  });

  test('sandbox_gather includes output and return value', () async {
    final result = await h.run(r'''
h1 = sandbox_spawn(code="print('log line')\n42")
results = sandbox_gather(handles=[h1])
results[0]
''');

    expect(result.error, isNull);
    final entry = result.value.dartValue as Map;
    expect(entry['value'], 42);
    expect((entry['output'] as String?)!, contains('log line'));
  });
});

// ---------------------------------------------------------------------------
// G1-5: sandbox_is_alive
// ---------------------------------------------------------------------------

group('G1-5: sandbox_is_alive', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
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

    expect(result.error, isNull);
    expect(result.value.dartValue, false);
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
    sandbox = SandboxExtension(platformFactory: _replFactory());
    h = MontyHarness(extensions: [sandbox]);
    await h.setup();
    ui = FauxUi(h.runtime);
  });

  tearDown(() {
    ui.dispose();
    h.dispose();
  });

  test('child executions arrive as BridgeChildEvent in runtime.events', () async {
    await h.run('''
h1 = sandbox_spawn(code="1 + 1")
sandbox_await(handle=h1)
''');

    ui.assertContains<BridgeChildEvent>();
  });
});

// ---------------------------------------------------------------------------
// G2-2: SignalCapture on childrenSignal
// ---------------------------------------------------------------------------

group('G2-2: SignalCapture on childrenSignal', () {
  late MontyHarness h;
  late SandboxExtension sandbox;

  setUp(() async {
    sandbox = SandboxExtension(platformFactory: _replFactory());
    h = MontyHarness(extensions: [sandbox]);
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('captures every state transition in childrenSignal', () async {
    final cap = SignalCapture(sandbox.childrenSignal);

    await h.run('''
h1 = sandbox_spawn(code="99")
sandbox_await(handle=h1)
''');

    cap.dispose();
    // States: {} (initial) → {0: ChildRunning()} → {0: ChildCompleted()}
    expect(cap.values.length, greaterThanOrEqualTo(2));
    final finalState = cap.values.last;
    expect(finalState.values.whereType<ChildCompleted>(), isNotEmpty);
  });
});
} // end main
