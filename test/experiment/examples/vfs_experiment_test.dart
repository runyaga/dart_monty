// G8: VFS / OsCall experiments.
//
// Covers write/read round-trips, Path.exists, OsCall bridge events,
// the harness in-memory filesystem, and denied paths.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/vfs_experiment_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import '../harness.dart';

void main() {
// ---------------------------------------------------------------------------
// G8-1: Dart writes, Python reads — round-trip
// ---------------------------------------------------------------------------

group('G8-1: Dart writes VFS file, Python reads', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..writeFile('/data/greet.txt', 'Hello from Dart')
      ..prime('from pathlib import Path');
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('Python reads Dart-written file via pathlib.Path', () async {
    final result = await h.run("Path('/data/greet.txt').read_text()");

    expect(result.error, isNull);
    expect(result.value.dartValue, 'Hello from Dart');
  });

  test('Python reads JSON-encoded file and parses it', () async {
    h.writeFile('/config/params.json', '{"rate": 3.14, "enabled": true}');

    final result = await h.run('''
import json
cfg = json.loads(Path('/config/params.json').read_text())
cfg['rate']
''');

    expect(result.error, isNull);
    expect((result.value.dartValue as double), closeTo(3.14, 0.001));
  });

  test('Python reads multiple files in a loop', () async {
    for (var i = 0; i < 3; i++) {
      h.writeFile('/items/item_$i.txt', 'item $i');
    }

    final result = await h.run('''
[Path(f'/items/item_{i}.txt').read_text() for i in range(3)]
''');

    expect(result.error, isNull);
    expect(result.value.dartValue, ['item 0', 'item 1', 'item 2']);
  });
});

// ---------------------------------------------------------------------------
// G8-2: Path.exists
// ---------------------------------------------------------------------------

group('G8-2: Path.exists', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..writeFile('/present.txt', 'here')
      ..prime('from pathlib import Path');
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('exists() returns True for written file', () async {
    final result = await h.run("Path('/present.txt').exists()");

    expect(result.error, isNull);
    expect(result.value.dartValue, true);
  });

  test('exists() returns False for absent file', () async {
    final result = await h.run("Path('/not_there.txt').exists()");

    expect(result.error, isNull);
    expect(result.value.dartValue, false);
  });
});

// ---------------------------------------------------------------------------
// G8-3: OsCall events appear in bridge stream
// ---------------------------------------------------------------------------

group('G8-3: OsCall events in bridge stream', () {
  late MontyHarness h;

  setUp(() async {
    h = MontyHarness()
      ..writeFile('/os_test.txt', 'content')
      ..prime('from pathlib import Path');
    await h.setup();
  });

  tearDown(() => h.dispose());

  test('BridgeOsCallStart events emitted for each VFS operation', () async {
    final (:result, :events) =
        await h.runWithEvents("Path('/os_test.txt').read_text()");

    expect(result.error, isNull);
    final osCalls = events.whereType<BridgeOsCallStart>().toList();
    expect(osCalls, isNotEmpty);
    expect(osCalls.any((e) => e.operationName.contains('read')), isTrue);
  });

  test('BridgeOsCallResult follows each BridgeOsCallStart', () async {
    final (:result, :events) =
        await h.runWithEvents("Path('/os_test.txt').exists()");

    expect(result.error, isNull);
    final starts = events.whereType<BridgeOsCallStart>().length;
    final results = events.whereType<BridgeOsCallResult>().length;
    expect(results, greaterThanOrEqualTo(starts));
  });
});

// ---------------------------------------------------------------------------
// G8-4: Harness VFS independence across test cases
// ---------------------------------------------------------------------------

group('G8-4: VFS isolation between harness instances', () {
  test('two harness instances have independent filesystems', () async {
    final h1 = MontyHarness()
      ..writeFile('/shared.txt', 'harness-one')
      ..prime('from pathlib import Path');
    final h2 = MontyHarness()
      ..writeFile('/shared.txt', 'harness-two')
      ..prime('from pathlib import Path');

    await h1.setup();
    await h2.setup();

    final r1 = await h1.run("Path('/shared.txt').read_text()");
    final r2 = await h2.run("Path('/shared.txt').read_text()");

    expect(r1.value.dartValue, 'harness-one');
    expect(r2.value.dartValue, 'harness-two');

    await h1.dispose();
    await h2.dispose();
  });

  test('writeFile after setup() is visible to subsequent run()', () async {
    final h = MontyHarness()..prime('from pathlib import Path');
    await h.setup();

    // Write after setup — should still be visible.
    h.writeFile('/late.txt', 'late write');
    final result = await h.run("Path('/late.txt').read_text()");

    expect(result.error, isNull);
    expect(result.value.dartValue, 'late write');

    await h.dispose();
  });
});
} // end main
