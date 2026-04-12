import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 1024,
  timeElapsedMs: 10,
  stackDepthUsed: 5,
);

void main() {
  late MockMontyPlatform mock;
  late EventLoopBridge bridge;

  setUp(() {
    mock = MockMontyPlatform();
    bridge = EventLoopBridge(platform: mock);
  });

  tearDown(() {
    if (bridge.loopState != EventLoopState.disposed) {
      bridge.dispose();
    }
  });

  group('recv and dispatch', () {
    test(
      'recv pauses, dispatch resumes with correct data',
      () async {
        // Python calls recv(), bridge handler creates Completer.
        // We use the sync (non-futures) path for simplicity: the bridge awaits
        // the handler inline, so we dispatch during that await.

        // Sequence: start -> Pending(recv) -> resume -> Complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('recv()');
        final sub = stream.listen(events.add);

        // Give the bridge time to reach the recv handler.
        await Future<void>.delayed(Duration.zero);

        expect(bridge.loopState, EventLoopState.waiting);

        // Dispatch a value.
        bridge.dispatch({'type': 'button_press', 'id': 'ok'});

        await sub.asFuture<void>();
        await sub.cancel();

        expect(bridge.loopState, EventLoopState.completed);

        // Verify the result was passed through resolveFutures.
        final resolvedResults = mock.lastResolveFuturesResults;
        expect(resolvedResults, isNotNull);
        expect(resolvedResults![1], isA<Map<String, dynamic>>());
        final resultMap = resolvedResults[1]! as Map<String, dynamic>;
        expect(resultMap['type'], 'button_press');
        expect(resultMap['id'], 'ok');
      },
    );

    test(
      'events queued while Python busy are delivered on next recv',
      () async {
        // First recv returns queued event, second waits for dispatch.
        mock
          // First call: emit
          ..enqueueProgress(
            const MontyPending(
              functionName: 'emit',
              arguments: [
                MontyDict({'type': MontyString('form')}),
              ],
              callId: 1,
            ),
          )
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
          // Second call: recv (will get queued event)
          ..enqueueProgress(
            const MontyPending(
              functionName: 'recv',
              arguments: [],
              callId: 2,
            ),
          )
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [2]))
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        // Queue an event BEFORE execution starts.
        bridge.dispatch({'type': 'early_click'});

        await bridge.execute('code').toList();

        // The queued event should have been returned immediately by
        // recv, no waiting needed.
        final resolvedResults = mock.resolveFuturesResultsList;
        expect(resolvedResults, hasLength(2));
        // Second resolve (recv) should contain the queued event.
        final waitResult = resolvedResults[1][2]! as Map<String, dynamic>;
        expect(waitResult['type'], 'early_click');
      },
    );

    test('multiple queued events delivered in FIFO order', () async {
      mock
        // First recv — will consume first queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        // Second recv — will consume second queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 2,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [2]))
        // Third recv — will consume third queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 3,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [3]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      // Queue 3 events BEFORE execution starts.
      bridge
        ..dispatch({'order': 1})
        ..dispatch({'order': 2})
        ..dispatch({'order': 3});

      await bridge.execute('loop').toList();

      // All three resolves should contain events in FIFO order.
      final results = mock.resolveFuturesResultsList;
      expect(results, hasLength(3));
      expect((results[0][1]! as Map)['order'], 1);
      expect((results[1][2]! as Map)['order'], 2);
      expect((results[2][3]! as Map)['order'], 3);
    });

    test('multiple sequential wait/dispatch cycles', () async {
      mock
        // First recv
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        // Second recv
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 2,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [2]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      final stream = bridge.execute('loop');
      final sub = stream.listen((_) {});

      // Wait for first recv.
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isWaiting, isTrue);
      bridge.dispatch({'cycle': 1});

      // Wait for second recv.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isWaiting, isTrue);
      bridge.dispatch({'cycle': 2});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(bridge.loopState, EventLoopState.completed);

      // Both resolves should have the correct events.
      expect(mock.resolveFuturesResultsList, hasLength(2));
      final first = mock.resolveFuturesResultsList[0][1]! as Map;
      expect(first['cycle'], 1);
      final second = mock.resolveFuturesResultsList[1][2]! as Map;
      expect(second['cycle'], 2);
    });
  });

  group('emit', () {
    test('stores value and invokes callback', () async {
      final emittedValues = <Map<String, dynamic>>[];
      bridge = EventLoopBridge(platform: mock, onEmit: emittedValues.add);

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'emit',
            arguments: [
              MontyDict({'type': MontyString('counter'), 'value': MontyInt(0)}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      await bridge.execute('emit(value)').toList();

      expect(bridge.lastEmitted, {'type': 'counter', 'value': 0});
      expect(emittedValues, hasLength(1));
      expect(emittedValues.first['type'], 'counter');
    });

    test('lastEmitted tracks most recent value', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'emit',
            arguments: [
              MontyDict({'version': MontyInt(1)}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyPending(
            functionName: 'emit',
            arguments: [
              MontyDict({'version': MontyInt(2)}),
            ],
            callId: 2,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [2]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      await bridge.execute('code').toList();

      expect(bridge.lastEmitted, {'version': 2});
    });
  });

  group('dispose', () {
    test('dispatch after dispose throws StateError', () {
      bridge.dispose();

      expect(() => bridge.dispatch({'type': 'click'}), throwsStateError);
    });

    test('script error while waiting cleans up orphaned Completer', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: MontyNull(),
              error: MontyException(message: 'kaboom'),
              usage: _usage,
            ),
          ),
        );

      final events = <BridgeEvent>[];
      final stream = bridge.execute('recv()');
      final sub = stream.listen(events.add);

      // Let bridge reach recv.
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isWaiting, isTrue);

      // Simulate the pending Completer being resolved with an error by the
      // bridge when the script errors — we dispatch to unblock the mock's
      // ResolveFutures step so the Complete(error) event can flow through.
      bridge.dispatch({'type': 'unblock'});

      await sub.asFuture<void>();
      await sub.cancel();

      // Bridge should be completed, not stuck in waiting.
      expect(bridge.loopState, EventLoopState.completed);

      // Verify a BridgeRunError was emitted.
      expect(events.whereType<BridgeRunError>(), isNotEmpty);
    });

    test('dispose while waiting completes with error', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: MontyNull(),
              error: MontyException(
                message: 'Bridge disposed while waiting for event',
              ),
              usage: _usage,
            ),
          ),
        );

      final events = <BridgeEvent>[];
      final stream = bridge.execute('recv()');
      final sub = stream.listen(events.add);

      // Let bridge reach recv.
      await Future<void>.delayed(Duration.zero);
      expect(bridge.isWaiting, isTrue);

      // Dispose while waiting.
      bridge.dispose();
      expect(bridge.loopState, EventLoopState.disposed);

      // The execution stream should finish (possibly with an error event).
      await sub.asFuture<void>();
      await sub.cancel();
    });
  });

  group('loopState transitions', () {
    test('idle -> executing -> completed', () async {
      expect(bridge.loopState, EventLoopState.idle);

      mock.enqueueProgress(
        const MontyComplete(
          result: MontyResult(value: MontyNull(), usage: _usage),
        ),
      );

      final stream = bridge.execute('42');

      // Should be executing after execute() is called.
      expect(bridge.loopState, EventLoopState.executing);

      await stream.toList();

      expect(bridge.loopState, EventLoopState.completed);
    });

    test(
      'idle -> executing -> waiting -> executing -> completed',
      () async {
        expect(bridge.loopState, EventLoopState.idle);

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNull(), usage: _usage),
            ),
          );

        final stream = bridge.execute('recv()');
        final sub = stream.listen((_) {});

        // Let it reach recv.
        await Future<void>.delayed(Duration.zero);
        expect(bridge.loopState, EventLoopState.waiting);

        bridge.dispatch({'type': 'click'});
        expect(bridge.loopState, EventLoopState.executing);

        await sub.asFuture<void>();
        await sub.cancel();
        expect(bridge.loopState, EventLoopState.completed);
      },
    );

    test('disposed state after dispose()', () {
      bridge.dispose();
      expect(bridge.loopState, EventLoopState.disposed);
    });
  });

  group('eventLoopEvents stream', () {
    test('emits BridgeEventLoopWaiting and BridgeEventLoopResumed', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      final loopEvents = <BridgeEvent>[];
      final loopSub = bridge.eventLoopEvents.listen(loopEvents.add);

      final stream = bridge.execute('recv()');
      final sub = stream.listen((_) {});

      await Future<void>.delayed(Duration.zero);

      bridge.dispatch({'type': 'tap'});

      await sub.asFuture<void>();
      await sub.cancel();
      await loopSub.cancel();

      expect(loopEvents.whereType<BridgeEventLoopWaiting>().length, 1);
      expect(loopEvents.whereType<BridgeEventLoopResumed>().length, 1);
      final resumed = loopEvents.whereType<BridgeEventLoopResumed>().first;
      expect(resumed.event['type'], 'tap');
    });

    test('emits BridgeEmitted when emit is called', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'emit',
            arguments: [
              MontyDict({'type': MontyString('label')}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      final loopEvents = <BridgeEvent>[];
      final loopSub = bridge.eventLoopEvents.listen(loopEvents.add);

      await bridge.execute('emit(value)').toList();

      await loopSub.cancel();

      final emitted = loopEvents.whereType<BridgeEmitted>().toList();
      expect(emitted, hasLength(1));
      expect(emitted.first.value['type'], 'label');
    });
  });

  group('host function registration', () {
    test('recv and emit are registered', () {
      final names = bridge.schemas.map((s) => s.name).toList();
      expect(names, contains('recv'));
      expect(names, contains('emit'));
    });
  });

  group('execute error paths', () {
    test('execute after dispose resets to idle and rethrows', () {
      bridge.dispose();

      // Calling execute on a disposed bridge throws from super.execute().
      // The EventLoopBridge.execute() catch block should reset state to idle
      // and rethrow. But since the bridge is already disposed, loopState
      // transitions to disposed via dispose(), so we can only test the throw.
      expect(() => bridge.execute('1'), throwsStateError);
    });

    test('execute sets state to idle on super.execute() error', () {
      // Create a bridge, start one execution so it's busy, then try to
      // execute again — this triggers the catch block.
      mock.enqueueProgress(
        const MontyPending(
          functionName: 'recv',
          arguments: [],
          callId: 1,
        ),
      );
      final stream = bridge.execute('recv()');

      // Bridge is now executing. A second execute should fail via
      // super.execute() StateError, and the catch block resets to idle.
      // However, loopState was already 'executing' from the override, so
      // the catch block sets it back to idle.
      expect(bridge.loopState, EventLoopState.executing);
      try {
        bridge.execute('2');
        fail('Should have thrown');
        // ignore: avoid_catching_errors – intentional: test verifies StateError recovery.
      } on StateError {
        // The catch in execute() rethrows. Since there's no loopState
        // visible between the throw and catch, we verify it does not crash.
      }

      // After the catch block, loopState should be reset to idle.
      expect(bridge.loopState, EventLoopState.idle);

      // Clean up: dispatch event and drain the stream.
      bridge.dispatch({'type': 'cleanup'});
      // Need to consume the stream to prevent hanging.
      unawaited(stream.drain<void>());
    });

    test(
      'orphaned completer cleaned up when script finishes with error',
      () async {
        // Scenario: Python calls recv and the handler waits, then
        // when the event is dispatched the resolveFutures step triggers an
        // error Complete, which flows through the execute() stream.map where
        // the orphaned completer should be cleaned up.
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                value: MontyNull(),
                error: MontyException(message: 'script died unexpectedly'),
                usage: _usage,
              ),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await Future<void>.delayed(Duration.zero);
        expect(bridge.isWaiting, isTrue);

        // Dispatch event to unblock the completer and let the error flow.
        bridge.dispatch({'type': 'trigger'});

        await sub.asFuture<void>();
        await sub.cancel();

        // Bridge should be completed (error event was emitted).
        expect(bridge.loopState, EventLoopState.completed);
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('script died unexpectedly'));
      },
    );

    test('run error while waiting cleans up orphaned completer', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: MontyNull(),
              error: MontyException(message: 'script crashed'),
              usage: _usage,
            ),
          ),
        );

      final events = <BridgeEvent>[];
      final stream = bridge.execute('recv()');
      final sub = stream.listen(events.add);

      await Future<void>.delayed(Duration.zero);
      expect(bridge.isWaiting, isTrue);

      // Dispatch to unblock, then the error Complete flows through.
      bridge.dispatch({'type': 'unblock'});

      await sub.asFuture<void>();
      await sub.cancel();

      // The stream.map handler in execute() should have completed the
      // orphaned completer with an error and set state to completed.
      expect(bridge.loopState, EventLoopState.completed);
      final errors = events.whereType<BridgeRunError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.message, contains('script crashed'));
    });
  });

  group('WASM fallback (sync-only platform)', () {
    test('recv works with sync-only platform', () async {
      final syncMock = _SyncOnlyMockPlatform();
      final syncBridge = EventLoopBridge(platform: syncMock);
      addTearDown(syncBridge.dispose);

      syncMock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNull(), usage: _usage),
          ),
        );

      final stream = syncBridge.execute('recv()');
      final sub = stream.listen((_) {});

      // Let it reach the handler.
      await Future<void>.delayed(Duration.zero);
      expect(syncBridge.isWaiting, isTrue);

      syncBridge.dispatch({'type': 'sync_click'});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(syncBridge.loopState, EventLoopState.completed);
      // Sync path uses resume() not resumeAsFuture().
      expect(syncMock.lastResumeReturnValue, isA<Map<String, dynamic>>());
      final result = syncMock.lastResumeReturnValue! as Map<String, dynamic>;
      expect(result['type'], 'sync_click');
    });
  });

  group('lifecycle and ownership', () {
    test('dispatch throws StateError when bridge is completed', () async {
      mock.enqueueProgress(
        const MontyComplete(result: MontyResult(usage: _usage)),
      );

      await bridge.execute('code').toList();
      expect(bridge.loopState, EventLoopState.completed);

      expect(() => bridge.dispatch({'type': 'too_late'}), throwsStateError);
    });

    test('dispatch is allowed after re-execute following completion', () async {
      // First execution completes.
      mock.enqueueProgress(
        const MontyComplete(result: MontyResult(usage: _usage)),
      );

      await bridge.execute('code').toList();
      expect(bridge.loopState, EventLoopState.completed);

      // Second execution starts — state transitions back to executing.
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      final stream = bridge.execute('recv()');
      final sub = stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);

      // Bridge is now waiting — dispatch must not throw.
      expect(() => bridge.dispatch({'type': 'ok'}), returnsNormally);

      await sub.asFuture<void>();
      await sub.cancel();
    });

    test('onEmit callback throwing does not produce a Python error', () async {
      bridge = EventLoopBridge(
        platform: mock,
        onEmit: (_) => throw Exception('callback blew up'),
      );

      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'emit',
            arguments: [
              MontyDict({'type': MontyString('event')}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(const MontyResolveFutures(pendingCallIds: [1]))
        ..enqueueProgress(
          const MontyComplete(result: MontyResult(usage: _usage)),
        );

      final events = await bridge.execute('emit(value)').toList();

      // The script should complete normally — the callback throwing
      // is a Dart-side side effect and must not become a Python error.
      expect(events.whereType<BridgeRunFinished>(), isNotEmpty);
      expect(events.whereType<BridgeRunError>(), isEmpty);
      // resumeWithError must NOT have been called — that would signal a
      // Python-level failure back to the interpreter.
      expect(mock.resumeErrorMessages, isEmpty);
    });
  });
}

/// Mock platform that does NOT implement [MontyFutureCapable].
///
/// Used to test that [EventLoopBridge] falls back to synchronous behavior
/// when the platform does not support futures (WASM).
class _SyncOnlyMockPlatform extends MontyPlatform {
  final Queue<MontyProgress> _progressQueue = Queue<MontyProgress>();
  final List<Object?> resumeReturnValues = [];
  final List<String> resumeErrorMessages = [];

  Object? get lastResumeReturnValue =>
      resumeReturnValues.isEmpty ? null : resumeReturnValues.last;

  void enqueueProgress(MontyProgress progress) {
    _progressQueue.add(progress);
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async => _dequeueProgress();

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    resumeReturnValues.add(returnValue);
    return _dequeueProgress();
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    resumeErrorMessages.add(errorMessage);
    return _dequeueProgress();
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async => throw UnimplementedError();

  @override
  Future<void> dispose() async {}

  MontyProgress _dequeueProgress() {
    if (_progressQueue.isEmpty) {
      throw StateError('No progress enqueued.');
    }
    return _progressQueue.removeFirst();
  }
}
