import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:test/test.dart';

/// Unit tests for [ExecutionHandle] construction + [CancelToken] semantics.
///
/// The sandbox-mode `MontyRuntime.execute()` integration tests exercise the
/// full events/result/cancel lifecycle end-to-end. These are pure-Dart
/// assertions on the handle's shape and the cancellation primitive.
void main() {
  group('CancelToken', () {
    test('starts un-cancelled with a non-completed future', () {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
      expect(
        Future.any([
          token.future.then((_) => 'cancelled'),
          Future<String>.value('still-alive'),
        ]),
        completion('still-alive'),
      );
    });

    test('cancel flips isCancelled and completes the future', () async {
      final token = CancelToken();
      final fired = token.future.then((_) => 'done');
      expect(token.isCancelled, isFalse);

      token.cancel();

      expect(token.isCancelled, isTrue);
      await expectLater(fired, completion('done'));
    });

    test('cancel is idempotent', () async {
      final token = CancelToken();
      token.cancel();
      token.cancel();
      token.cancel();

      expect(token.isCancelled, isTrue);
      await expectLater(token.future, completes);
    });
  });

  group('ExecutionHandle', () {
    test('exposes events, result, executionId, and cancel', () async {
      final token = CancelToken();
      final stubResult = MontyResult(
        value: const MontyNone(),
        usage: const MontyResourceUsage(
          memoryBytesUsed: 0,
          timeElapsedMs: 0,
          stackDepthUsed: 0,
        ),
      );
      final handle = ExecutionHandle(
        events: const Stream<BridgeEvent>.empty(),
        result: Future.value(stubResult),
        executionId: 'exec-7',
        cancel: () async => token.cancel(),
      );

      expect(handle.executionId, 'exec-7');
      expect(await handle.events.toList(), isEmpty);
      expect(await handle.result, same(stubResult));
      await handle.cancel();
      expect(token.isCancelled, isTrue);
    });
  });
}
