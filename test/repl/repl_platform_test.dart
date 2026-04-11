import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:test/test.dart';

import '../ffi/mock_native_bindings.dart';

void main() {
  group('ReplPlatform', () {
    late MockNativeBindings mock;
    late MontyRepl repl;
    late ReplPlatform platform;

    setUp(() {
      mock = MockNativeBindings();
      final bindings = FfiReplBindings(bindings: mock);
      repl = MontyRepl.withBindings(bindings: bindings);
      platform = ReplPlatform(repl: repl);
    });

    tearDown(() async {
      await platform.dispose();
    });

    test('run delegates to feed', () async {
      mock.nextReplFeedRunResult = const RunResult(
        tag: 0,
        resultJson:
            '{"value": 4, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      final result = await platform.run('2 + 2');
      expect(result.value, const MontyInt(4));
    });

    test('start delegates to feedStart', () async {
      mock.nextReplFeedStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fetch',
        argumentsJson: '["url"]',
        kwargsJson: '{}',
        callId: 0,
        methodCall: false,
      );

      final progress = await platform.start(
        'fetch("url")',
        externalFunctions: ['fetch'],
      );
      expect(progress, isA<MontyPending>());
      expect((progress as MontyPending).functionName, 'fetch');
    });

    test('resume delegates to repl resume', () async {
      // First start so the repl is in a pending state
      mock.nextReplFeedStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
        argumentsJson: '[]',
        kwargsJson: '{}',
        callId: 0,
      );
      await platform.start('fn()', externalFunctions: ['fn']);

      // Resume — mock returns complete by default
      final progress = await platform.resume(42);
      expect(progress, isA<MontyComplete>());
    });

    test('resumeWithError delegates', () async {
      mock.nextReplFeedStartResult = const ProgressResult(
        tag: 1,
        functionName: 'fn',
        argumentsJson: '[]',
        kwargsJson: '{}',
        callId: 0,
      );
      await platform.start('fn()', externalFunctions: ['fn']);

      final progress = await platform.resumeWithError('oops');
      expect(progress, isA<MontyComplete>());
    });
  });
}
