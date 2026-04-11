import 'package:dart_monty/src/ffi/native_bindings.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:dart_monty/src/repl/monty_repl.dart';
import 'package:test/test.dart';

import '../ffi/mock_native_bindings.dart';

void main() {
  group('MontyRepl (mock FFI)', () {
    late MockNativeBindings mock;
    late MontyRepl repl;

    setUp(() {
      mock = MockNativeBindings();
      final bindings = FfiReplBindings(bindings: mock);
      repl = MontyRepl.withBindings(bindings: bindings);
    });

    tearDown(() async {
      await repl.dispose();
    });

    test('feed creates REPL on first call', () async {
      mock.nextReplFeedRunResult = const RunResult(
        tag: 0,
        resultJson:
            '{"value": 42, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      final result = await repl.feed('x = 42');
      expect(mock.replCreateCalls, hasLength(1));
      expect(result.value, isNotNull);
    });

    test('feed does not recreate on subsequent calls', () async {
      mock.nextReplFeedRunResult = const RunResult(
        tag: 0,
        resultJson:
            '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
      );

      await repl.feed('x = 1');
      await repl.feed('x + 1');

      expect(mock.replCreateCalls, hasLength(1));
      // 2 bootstrap feeds (registry + help def) + 2 user feeds = 4
      expect(mock.replFeedRunCalls, hasLength(4));
    });

    test('detectContinuation returns correct mode', () async {
      mock.nextReplDetectContinuation = 2;

      final mode = await repl.detectContinuation('def f():');
      expect(mode, ReplContinuationMode.incompleteBlock);
    });

    test('dispose frees REPL handle', () async {
      await repl.feed('x = 1');
      await repl.dispose();

      expect(mock.replFreeCalls, hasLength(1));
    });

    test('feed after dispose throws', () async {
      await repl.dispose();
      expect(() => repl.feed('x'), throwsStateError);
    });

    test('feed returns print output', () async {
      mock.nextReplFeedRunResult = const RunResult(
        tag: 0,
        resultJson:
            '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}, '
            r'"print_output": "hello\n"}',
      );

      final result = await repl.feed("print('hello')");
      expect(result.printOutput, 'hello\n');
    });

    test('feed with error returns MontyResult with error', () async {
      mock.nextReplFeedRunResult = const RunResult(
        tag: 0,
        resultJson:
            '{"value": null, "usage": {"memory_bytes_used": 0, '
            '"time_elapsed_ms": 0, "stack_depth_used": 0}, '
            '"error": {"message": "name \'y\' is not defined", '
            '"exc_type": "NameError"}}',
      );

      final result = await repl.feed('y');
      expect(result.error, isNotNull);
      expect(result.error!.message, "name 'y' is not defined");
      expect(result.error!.excType, 'NameError');
    });
  });

  group('ReplContinuationMode', () {
    test('all values', () {
      expect(ReplContinuationMode.values, hasLength(3));
      expect(ReplContinuationMode.complete.name, 'complete');
      expect(
        ReplContinuationMode.incompleteImplicit.name,
        'incompleteImplicit',
      );
      expect(
        ReplContinuationMode.incompleteBlock.name,
        'incompleteBlock',
      );
    });
  });

  group('FfiReplBindings', () {
    test('feedRun before create throws StateError', () async {
      final mock = MockNativeBindings();
      final bindings = FfiReplBindings(bindings: mock);

      expect(
        () => bindings.feedRun('x'),
        throwsStateError,
      );
    });

    test('translateRunResult parses ok result', () async {
      final mock = MockNativeBindings()
        ..nextReplFeedRunResult = const RunResult(
          tag: 0,
          resultJson:
              '{"value": 99, "usage": {"memory_bytes_used": 0, '
              '"time_elapsed_ms": 0, "stack_depth_used": 0}}',
        );
      final bindings = FfiReplBindings(bindings: mock);
      await bindings.create();

      final result = await bindings.feedRun('99');
      expect(result.ok, isTrue);
      expect(result.value, 99);
    });

    test('translateRunResult parses error result', () async {
      final mock = MockNativeBindings()
        ..nextReplFeedRunResult = const RunResult(
          tag: 1,
          resultJson:
              '{"value": null, "error": {"message": "boom", '
              '"exc_type": "RuntimeError"}}',
          errorMessage: 'boom',
        );
      final bindings = FfiReplBindings(bindings: mock);
      await bindings.create();

      final result = await bindings.feedRun('raise RuntimeError("boom")');
      expect(result.ok, isFalse);
      expect(result.error, 'boom');
      expect(result.excType, 'RuntimeError');
    });
  });
}
