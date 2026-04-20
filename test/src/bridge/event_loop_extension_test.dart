import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/dart_monty_testing.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

const _usage = MontyResourceUsage(
  memoryBytesUsed: 1024,
  timeElapsedMs: 10,
  stackDepthUsed: 5,
);

void main() {
  late MockMontyPlatform mock;
  late DefaultMontyBridge bridge;
  late EventLoopExtension plugin;

  setUp(() async {
    mock = MockMontyPlatform();
    plugin = EventLoopExtension();
    bridge = DefaultMontyBridge(platform: mock);
    await plugin.onAttach(bridge);
    for (final fn in plugin.functions) {
      bridge.register(fn, category: plugin.namespace);
    }
  });

  tearDown(() async {
    await plugin.onDispose();
    bridge.dispose();
  });

  group('recv and dispatch', () {
    test(
      'recv pauses, dispatch resumes with correct data',
      () async {
        // Python calls el_recv(), bridge handler creates Completer.
        // We use the sync (non-futures) path for simplicity: the bridge
        // awaits the handler inline, so we dispatch during that await.

        // Sequence: start -> Pending(el_recv) -> resume -> Complete
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Give the bridge time to reach the recv handler.
        await Future<void>.delayed(Duration.zero);

        expect(plugin.channelState, isA<BridgeChannelWaiting>());

        // Dispatch a value.
        plugin.dispatch({'type': 'button_press', 'id': 'ok'});

        await sub.asFuture<void>();
        await sub.cancel();

        expect(plugin.channelState, const BridgeChannelCompleted());

        // Verify the result was passed through resolveFutures.
        final resolvedResults = mock.history.lastResolveFuturesResults;
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
          // First call: el_emit
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_emit',
              arguments: [
                MontyDict({'type': MontyString('form')}),
              ],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          // Second call: el_recv (will get queued event)
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 2,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [2]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        // Queue an event BEFORE execution starts.
        plugin.dispatch({'type': 'early_click'});

        await bridge.execute('code').toList();

        // The queued event should have been returned immediately by
        // el_recv, no waiting needed.
        final resolvedResults = mock.history.resolveFuturesResultsList;
        expect(resolvedResults, hasLength(2));
        // Second resolve (recv) should contain the queued event.
        final waitResult = resolvedResults[1][2]! as Map<String, dynamic>;
        expect(waitResult['type'], 'early_click');
      },
    );

    test('multiple queued events delivered in FIFO order', () async {
      mock
        // First el_recv — will consume first queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        // Second el_recv — will consume second queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 2,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [2]),
        )
        // Third el_recv — will consume third queued event.
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 3,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [3]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      // Queue 3 events BEFORE execution starts.
      plugin
        ..dispatch({'order': 1})
        ..dispatch({'order': 2})
        ..dispatch({'order': 3});

      await bridge.execute('loop').toList();

      // All three resolves should contain events in FIFO order.
      final results = mock.history.resolveFuturesResultsList;
      expect(results, hasLength(3));
      expect((results[0][1]! as Map)['order'], 1);
      expect((results[1][2]! as Map)['order'], 2);
      expect((results[2][3]! as Map)['order'], 3);
    });

    test('multiple sequential wait/dispatch cycles', () async {
      mock
        // First el_recv
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        // Second el_recv
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 2,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [2]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final stream = bridge.execute('loop');
      final sub = stream.listen((_) {});

      // Wait for first recv.
      await Future<void>.delayed(Duration.zero);
      expect(plugin.isWaiting, isTrue);
      plugin.dispatch({'cycle': 1});

      // Wait for second recv.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(plugin.isWaiting, isTrue);
      plugin.dispatch({'cycle': 2});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(plugin.channelState, const BridgeChannelCompleted());

      // Both resolves should have the correct events.
      expect(mock.history.resolveFuturesResultsList, hasLength(2));
      final first = mock.history.resolveFuturesResultsList[0][1]! as Map;
      expect(first['cycle'], 1);
      final second = mock.history.resolveFuturesResultsList[1][2]! as Map;
      expect(second['cycle'], 2);
    });
  });

  group('emit', () {
    test('stores value in lastEmitted', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_emit',
            arguments: [
              MontyDict({
                'type': MontyString('counter'),
                'value': MontyInt(0),
              }),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('el_emit(value)').toList();

      expect(plugin.lastEmitted, {'type': 'counter', 'value': 0});
    });

    test('lastEmitted tracks most recent value', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_emit',
            arguments: [
              MontyDict({'version': MontyInt(1)}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_emit',
            arguments: [
              MontyDict({'version': MontyInt(2)}),
            ],
            callId: 2,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [2]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      await bridge.execute('code').toList();

      expect(plugin.lastEmitted, {'version': 2});
    });
  });

  group('dispose', () {
    test('dispatch after dispose throws StateError', () async {
      await plugin.onDispose();

      expect(
        () => plugin.dispatch({'type': 'click'}),
        throwsStateError,
      );
    });

    test(
      'script error while waiting cleans up orphaned Completer',
      () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                value: MontyNone(),
                error: MontyException(message: 'kaboom'),
                usage: _usage,
              ),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await Future<void>.delayed(Duration.zero);
        expect(plugin.isWaiting, isTrue);

        // Simulate the pending Completer being resolved with an error by
        // the bridge when the script errors — we dispatch to unblock the
        // mock's ResolveFutures step so the Complete(error) event can
        // flow through.
        plugin.dispatch({'type': 'unblock'});

        await sub.asFuture<void>();
        await sub.cancel();

        // Plugin should be completed, not stuck in waiting.
        expect(plugin.channelState, const BridgeChannelCompleted());

        // Verify a BridgeRunError was emitted.
        expect(events.whereType<BridgeRunError>(), isNotEmpty);
      },
    );

    test('dispose while waiting completes with error', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(
              value: MontyNone(),
              error: MontyException(
                message: 'Bridge disposed while waiting for event',
              ),
              usage: _usage,
            ),
          ),
        );

      final events = <BridgeEvent>[];
      final stream = bridge.execute('el_recv()');
      final sub = stream.listen(events.add);

      // Let bridge reach recv.
      await Future<void>.delayed(Duration.zero);
      expect(plugin.isWaiting, isTrue);

      // Dispose while waiting.
      await plugin.onDispose();
      expect(plugin.channelState, const BridgeChannelDisposed());

      // The execution stream should finish (possibly with an error event).
      await sub.asFuture<void>();
      await sub.cancel();
    });
  });

  group('channelState transitions', () {
    test('idle -> executing -> completed', () async {
      expect(plugin.channelState, const BridgeChannelIdle());

      mock.enqueueProgress(
        const MontyComplete(
          result: MontyResult(value: MontyNone(), usage: _usage),
        ),
      );

      final stream = bridge.execute('42');

      // Should be executing after execute() is called.
      expect(plugin.channelState, const BridgeChannelExecuting());

      await stream.toList();

      expect(plugin.channelState, const BridgeChannelCompleted());
    });

    test(
      'idle -> executing -> waiting -> executing -> completed',
      () async {
        expect(plugin.channelState, const BridgeChannelIdle());

        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});

        // Let it reach recv.
        await Future<void>.delayed(Duration.zero);
        expect(plugin.channelState, isA<BridgeChannelWaiting>());

        plugin.dispatch({'type': 'click'});
        expect(plugin.channelState, const BridgeChannelExecuting());

        await sub.asFuture<void>();
        await sub.cancel();
        expect(plugin.channelState, const BridgeChannelCompleted());
      },
    );

    test('disposed state after onDispose()', () async {
      await plugin.onDispose();
      expect(plugin.channelState, const BridgeChannelDisposed());
    });
  });

  group('signals', () {
    test(
      'channelStateSignal reflects transitions through waiting',
      () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final states = <BridgeChannelState>[];
        final cleanup = effect(
          () => states.add(plugin.channelStateSignal.value),
        );

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});

        await Future<void>.delayed(Duration.zero);

        plugin.dispatch({'type': 'tap'});

        await sub.asFuture<void>();
        await sub.cancel();
        cleanup();

        // States collected: idle (initial effect run), executing, waiting,
        // executing (dispatch), completed.
        expect(states, [
          isA<BridgeChannelIdle>(),
          isA<BridgeChannelExecuting>(),
          isA<BridgeChannelWaiting>(),
          isA<BridgeChannelExecuting>(),
          isA<BridgeChannelCompleted>(),
        ]);
      },
    );

    test('lastEmittedSignal updates when el_emit is called', () async {
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_emit',
            arguments: [
              MontyDict({'type': MontyString('label')}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final emitted = <Map<String, dynamic>?>[];
      final cleanup = effect(
        () => emitted.add(plugin.lastEmittedSignal.value),
      );

      await bridge.execute('el_emit(value)').toList();
      cleanup();

      // Initial null + one update from emit.
      expect(emitted.where((e) => e != null), hasLength(1));
      expect(emitted.last?['type'], 'label');
    });
  });

  group('host function registration', () {
    test('el_recv and el_emit are registered', () {
      final names = bridge.schemas.map((s) => s.name).toList();
      expect(names, contains('el_recv'));
      expect(names, contains('el_emit'));
    });
  });

  group('execute error paths', () {
    test('plugin state stays idle when execute() throws StateError', () {
      bridge.dispose();
      expect(plugin.channelState, const BridgeChannelIdle());
      expect(() => bridge.execute('1'), throwsStateError);
      // onAttach was called but _wrapStream was never called — state remains idle
      expect(plugin.channelState, const BridgeChannelIdle());
    });

    test('execute after plugin dispose throws', () async {
      await plugin.onDispose();
      bridge.dispose();
      expect(() => bridge.execute('1'), throwsStateError);
    });

    test(
      'orphaned completer cleaned up when script finishes with error',
      () async {
        // Scenario: Python calls el_recv and the handler waits, then
        // when the event is dispatched the resolveFutures step triggers
        // an error Complete, which flows through the execute() stream.map
        // where the orphaned completer should be cleaned up.
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                value: MontyNone(),
                error: MontyException(
                  message: 'script died unexpectedly',
                ),
                usage: _usage,
              ),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await Future<void>.delayed(Duration.zero);
        expect(plugin.isWaiting, isTrue);

        // Dispatch event to unblock the completer and let the error flow.
        plugin.dispatch({'type': 'trigger'});

        await sub.asFuture<void>();
        await sub.cancel();

        // Plugin should be completed (error event was emitted).
        expect(plugin.channelState, const BridgeChannelCompleted());
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('script died unexpectedly'));
      },
    );

    test(
      'run error while waiting cleans up orphaned completer',
      () async {
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(
                value: MontyNone(),
                error: MontyException(message: 'script crashed'),
                usage: _usage,
              ),
            ),
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        await Future<void>.delayed(Duration.zero);
        expect(plugin.isWaiting, isTrue);

        // Dispatch to unblock, then the error Complete flows through.
        plugin.dispatch({'type': 'unblock'});

        await sub.asFuture<void>();
        await sub.cancel();

        // The stream.map handler should have completed the orphaned
        // completer with an error and set state to completed.
        expect(plugin.channelState, const BridgeChannelCompleted());
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('script crashed'));
      },
    );
  });

  group('WASM fallback (sync-only platform)', () {
    test('el_recv works with sync-only platform', () async {
      final syncMock = _SyncOnlyMockPlatform();
      final syncPlugin = EventLoopExtension();
      final syncBridge = DefaultMontyBridge(
        platform: syncMock,
        useFutures: false,
      );
      await syncPlugin.onAttach(syncBridge);
      for (final fn in syncPlugin.functions) {
        syncBridge.register(fn, category: syncPlugin.namespace);
      }
      addTearDown(() async {
        await syncPlugin.onDispose();
        syncBridge.dispose();
      });

      syncMock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_recv',
            arguments: [],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final stream = syncBridge.execute('el_recv()');
      final sub = stream.listen((_) {});

      // Let it reach the handler.
      await Future<void>.delayed(Duration.zero);
      expect(syncPlugin.isWaiting, isTrue);

      syncPlugin.dispatch({'type': 'sync_click'});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(syncPlugin.channelState, const BridgeChannelCompleted());
      // Sync path uses resume() not resumeAsFuture().
      expect(
        syncMock.lastResumeReturnValue,
        isA<Map<String, dynamic>>(),
      );
      final result = syncMock.lastResumeReturnValue! as Map<String, dynamic>;
      expect(result['type'], 'sync_click');
    });
  });

  group('lifecycle and ownership', () {
    test('dispatch throws StateError when plugin is completed', () async {
      mock.enqueueProgress(
        const MontyComplete(
          result: MontyResult(value: MontyNone(), usage: _usage),
        ),
      );

      await bridge.execute('code').toList();
      expect(plugin.channelState, const BridgeChannelCompleted());

      expect(
        () => plugin.dispatch({'type': 'too_late'}),
        throwsStateError,
      );
    });

    test(
      'dispatch is allowed after re-execute following completion',
      () async {
        // First execution completes.
        mock.enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

        await bridge.execute('code').toList();
        expect(plugin.channelState, const BridgeChannelCompleted());

        // Second execution starts — state transitions back to executing.
        mock
          ..enqueueProgress(
            const MontyPending(
              functionName: 'el_recv',
              arguments: [],
              callId: 1,
            ),
          )
          ..enqueueProgress(
            const MontyResolveFutures(pendingCallIds: [1]),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});
        await Future<void>.delayed(Duration.zero);

        // Plugin is now waiting — dispatch must not throw.
        expect(
          () => plugin.dispatch({'type': 'ok'}),
          returnsNormally,
        );

        await sub.asFuture<void>();
        await sub.cancel();
      },
    );

    test('el_emit does not cause execution error', () async {
      // Structural property: _handleEmit only updates a signal.
      // No callback path exists that could throw and propagate to
      // DefaultMontyBridge.resumeWithError(). This test verifies that
      // invariant end-to-end.
      mock
        ..enqueueProgress(
          const MontyPending(
            functionName: 'el_emit',
            arguments: [
              MontyDict({'type': MontyString('event')}),
            ],
            callId: 1,
          ),
        )
        ..enqueueProgress(
          const MontyResolveFutures(pendingCallIds: [1]),
        )
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );

      final events = await bridge.execute('el_emit(value)').toList();

      expect(events.whereType<BridgeRunFinished>(), isNotEmpty);
      expect(events.whereType<BridgeRunError>(), isEmpty);
      expect(mock.history.resumeErrorMessages, isEmpty);
    });
  });

  group('bridge locking regression', () {
    test(
      'wrapper exception resets _isExecuting immediately (not after _run)',
      () async {
        // Regression: without the try-catch in DefaultMontyBridge.execute(),
        // a synchronously-throwing wrapper leaves _isExecuting = true until
        // _run's whenComplete fires. The very next execute() call (before any
        // microtask yields) would throw 'Bridge is already executing' even
        // though the first call failed before producing a valid stream.
        final lockMock = MockMontyPlatform();
        final lockBridge = DefaultMontyBridge(
          platform: lockMock,
          useFutures: false,
        );
        addTearDown(lockBridge.dispose);

        var wrapperCalls = 0;
        lockBridge.addStreamWrapper((code, stream) {
          // Throw on the first call only so the second execute() can succeed.
          if (wrapperCalls++ == 0) {
            throw StateError('intentional wrapper failure');
          }

          return stream;
        });

        // Enqueue one completion for the background _run that the first
        // (failed) execute() starts, and one for the successful re-execute.
        lockMock
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          )
          ..enqueueProgress(
            const MontyComplete(
              result: MontyResult(value: MontyNone(), usage: _usage),
            ),
          );

        // First call: wrapper throws synchronously.
        expect(() => lockBridge.execute('first'), throwsStateError);

        // Re-execute synchronously (no await — _run from call 1 hasn't
        // completed yet). Without the fix: throws 'Bridge is already
        // executing'. With the fix: _isExecuting was reset in the catch
        // block so this proceeds normally.
        final stream = lockBridge.execute('second');
        final events = await stream.toList();
        expect(events.whereType<BridgeRunFinished>(), isNotEmpty);
      },
    );
  });

  group('createChildInstance', () {
    test(
      'returns a fresh EventLoopExtension for child sandboxes',
      () async {
        // Regression: without the createChildInstance override the default
        // returns null. SandboxExtension treats null as "plugin not needed in
        // child", so child bridges get no EventLoopExtension. Python code inside
        // a child sandbox that calls el_recv() or el_emit() would raise
        // NameError because those host functions were never registered.
        final child = plugin.createChildInstance(
          const ChildSpawnContext(childId: 1),
        );

        expect(
          child,
          isNotNull,
          reason: 'child sandboxes must inherit event loop capability',
        );
        expect(child, isA<EventLoopExtension>());
        expect(
          child,
          isNot(same(plugin)),
          reason: 'must be a fresh independent instance',
        );

        final childPlugin = child as EventLoopExtension;
        expect(childPlugin.channelState, const BridgeChannelIdle());

        // Disposing the child must not affect the parent.
        await childPlugin.onDispose();
        expect(plugin.channelState, isNot(const BridgeChannelDisposed()));
      },
    );
  });

  group('ExtensionCoordinator integration', () {
    test('ExtensionCoordinator.attachTo wires stream wrapper', () async {
      final mock2 = MockMontyPlatform()
        ..enqueueProgress(
          const MontyComplete(
            result: MontyResult(value: MontyNone(), usage: _usage),
          ),
        );
      final plugin2 = EventLoopExtension();
      final registry = ExtensionCoordinator()..register(plugin2);
      final bridge2 = DefaultMontyBridge(platform: mock2);
      await registry.attachTo(bridge2);

      final events = await bridge2.execute('pass').toList();
      expect(events.whereType<BridgeRunFinished>(), hasLength(1));
      expect(plugin2.channelState, const BridgeChannelCompleted());

      await registry.disposeAll();
      bridge2.dispose();
    });
  });
}

/// Mock platform that does NOT implement [MontyFutureCapable].
///
/// Used to test that EventLoopExtension falls back to synchronous behaviour
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
