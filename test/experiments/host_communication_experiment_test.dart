// G7: Dart↔host communication experiments.
//
// Covers MontyRuntime.invoke() from Dart, ctx.emitText(), HostContext fields,
// clearState(), state persistence across execute() calls, and per-execute
// execution ids.
//
// Run with:
//   dart test --tags=integration \
//     test/experiment/examples/host_communication_experiment_test.dart
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

import 'harness.dart';

void main() {
  // ---------------------------------------------------------------------------
  // G7-1: invoke() from Dart — bypasses Python entirely
  // ---------------------------------------------------------------------------

  group('G7-1: invoke() from Dart', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool(
          'add',
          (args, ctx) async => (args['a']! as int) + (args['b']! as int),
          params: [
            const HostParam(name: 'a', type: HostParamType.integer),
            const HostParam(name: 'b', type: HostParamType.integer),
          ],
        );
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('invoke() returns handler result without Python', () async {
      final result = await h.runtime.invoke('add', {'a': 3, 'b': 4});
      expect(result, 7);
    });

    test('invoke() goes through the recorder — call is recorded', () async {
      await h.runtime.invoke('add', {'a': 1, 'b': 1});
      h.assertCalled('add', args: {'a': 1, 'b': 1});
    });

    test('invoke() and Python calls share the same recorder', () async {
      await h.runtime.invoke('add', {'a': 10, 'b': 0});
      await h.run('add(a=5, b=3)');

      h.assertCallCount('add', 2);
    });
  });

  // ---------------------------------------------------------------------------
  // G7-2: ctx.emitText() — text emissions visible in event stream
  // ---------------------------------------------------------------------------

  group('G7-2: ctx.emitText() in host handler', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness()
        ..registerTool('stream_words', (args, ctx) async {
          ctx
            ..emitText('Hello ')
            ..emitText('world');
          return 'done';
        });
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('BridgeFunctionEmit events appear for each emitText call', () async {
      final (:result, :events) = await h.runWithEvents('stream_words()');

      expect(result.error, isNull);
      final emits = events.whereType<BridgeFunctionEmit>().toList();
      expect(emits, isNotEmpty);
      final texts = emits.map((e) => e.text).join();
      expect(texts, contains('Hello'));
      expect(texts, contains('world'));
    });
  });

  // ---------------------------------------------------------------------------
  // G7-3: State persistence across execute() calls
  // ---------------------------------------------------------------------------

  group('G7-3: state persists across execute() calls', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness();
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('variable defined in first call is accessible in second', () async {
      await h.run('x = 42');
      final result = await h.run('x + 1');

      expect(result.error, isNull);
      expect(result.value.dartValue, 43);
    });

    test('function defined in first call is callable in second', () async {
      await h.run('def double(n): return n * 2');
      final result = await h.run('double(7)');

      expect(result.error, isNull);
      expect(result.value.dartValue, 14);
    });
  });

  // ---------------------------------------------------------------------------
  // G7-4: clearState() resets Python globals
  // ---------------------------------------------------------------------------

  group('G7-4: clearState() wipes Python globals', () {
    late MontyHarness h;

    setUp(() async {
      h = MontyHarness();
      await h.setup();
    });

    tearDown(() => h.dispose());

    test('after clearState, previously defined var is gone', () async {
      await h.run('secret = 99');
      h.runtime.clearState();

      final result = await h.run('secret');
      expect(result.error, isNotNull); // NameError
    });

    test('after clearState, new definitions work normally', () async {
      await h.run('old = 1');
      h.runtime.clearState();
      await h.run('fresh = 2');

      final result = await h.run('fresh');
      expect(result.error, isNull);
      expect(result.value.dartValue, 2);
    });
  });

  // ---------------------------------------------------------------------------
  // G7-7: HostContext.executionId is unique per execute()
  // ---------------------------------------------------------------------------

  group('G7-7: executionId uniqueness', () {
    late MontyHarness h;
    final execIds = <String>[];

    setUp(() async {
      h = MontyHarness()
        ..registerTool('capture_id', (args, ctx) async {
          execIds.add(ctx.executionId);
          return ctx.executionId;
        });
      await h.setup();
    });

    tearDown(() async {
      execIds.clear();
      await h.dispose();
    });

    test('executionId differs across two execute() calls', () async {
      await h.run('capture_id()');
      await h.run('capture_id()');

      expect(execIds, hasLength(2));
      expect(execIds.first, isNot(execIds.last));
    });

    test(
      'each tool invocation gets a unique executionId within one execute()',
      () async {
        await h.run('capture_id(); capture_id()');

        expect(execIds, hasLength(2));
        // Each call gets its own call-scoped ID — they differ within one
        // execute().
        expect(execIds.first, isNot(execIds.last));
      },
    );
  });
} // end main
