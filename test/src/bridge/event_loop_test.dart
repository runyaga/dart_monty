import 'dart:async';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extensions/event_loop.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:dart_monty_core/dart_monty_core_testing.dart';
import 'package:signals_core/signals_core.dart';
import 'package:test/test.dart';

/// Waits, one event-loop turn at a time, until [condition] holds; fails
/// after [turns] turns. No timer: each turn is a zero-duration delay.
Future<void> _until(bool Function() condition, {int turns = 1000}) async {
  for (var i = 0; i < turns; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not reached after $turns event-loop turns');
}

/// The values the host answered with, in order: a settled future's value
/// or a call's return value.
List<Object> _returnAnswers(FakeMontySession session) => [
  for (final a in session.answers)
    if (a.answer case ExternalReturnValue(:final value)) value,
];

/// The answer [value] as plain Dart data.
Object? _dart(Object value) => (value as MontyValue).dartValue;

void main() {
  late FakeMontySession fake;
  late SessionBridge bridge;
  late EventLoopExtension plugin;

  setUp(() async {
    fake = FakeMontySession();
    plugin = EventLoopExtension();
    bridge = SessionBridge(session: fake);
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
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willReturn(const MontyNone());

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Give the bridge time to reach the recv handler.
        await _until(() => plugin.isWaiting);
        expect(plugin.channelState, isA<EventLoopWaiting>());

        // Dispatch a value.
        plugin.dispatch({'type': 'button_press', 'id': 'ok'});

        await sub.asFuture<void>();
        await sub.cancel();

        expect(plugin.channelState, const EventLoopCompleted());

        // Verify the result settled the awaited future.
        final resolvedResults = _returnAnswers(fake);
        expect(resolvedResults, hasLength(1));
        expect(_dart(resolvedResults.single), isA<Map<String, Object?>>());
        final resultMap = _dart(resolvedResults.single)! as Map;
        expect(resultMap['type'], 'button_press');
        expect(resultMap['id'], 'ok');
      },
    );

    test(
      'events queued while Python busy are delivered on next recv',
      () async {
        // First recv returns queued event, second waits for dispatch.
        fake
          // First call: el_emit
          ..willCall(
            'el_emit',
            args: [
              const MontyDict([(MontyString('type'), MontyString('form'))]),
            ],
          )
          ..willAwait([0])
          // Second call: el_recv (will get queued event)
          ..willCall('el_recv')
          ..willAwait([1])
          ..willReturn(const MontyNone());

        // Queue an event BEFORE execution starts.
        plugin.dispatch({'type': 'early_click'});

        await bridge.execute('code').toList();

        // The queued event should have been returned immediately by
        // el_recv, no waiting needed.
        final resolvedResults = _returnAnswers(fake);
        expect(resolvedResults, hasLength(2));
        // Second answer (recv) should contain the queued event.
        final waitResult = _dart(resolvedResults[1])! as Map;
        expect(waitResult['type'], 'early_click');
      },
    );

    test(
      'multiple queued events delivered in FIFO order',
      () async {
        fake
          // First el_recv — will consume first queued event.
          ..willCall('el_recv')
          ..willAwait([0])
          // Second el_recv — will consume second queued event.
          ..willCall('el_recv')
          ..willAwait([1])
          // Third el_recv — will consume third queued event.
          ..willCall('el_recv')
          ..willAwait([2])
          ..willReturn(const MontyNone());

        // Queue 3 events BEFORE execution starts.
        plugin
          ..dispatch({'order': 1})
          ..dispatch({'order': 2})
          ..dispatch({'order': 3});

        await bridge.execute('loop').toList();

        // All three resolves should contain events in FIFO order.
        final results = _returnAnswers(fake);
        expect(results, hasLength(3));
        expect((_dart(results[0])! as Map)['order'], 1);
        expect((_dart(results[1])! as Map)['order'], 2);
        expect((_dart(results[2])! as Map)['order'], 3);
      },
    );

    test('multiple sequential wait/dispatch cycles', () async {
      fake
        // First el_recv
        ..willCall('el_recv')
        ..willAwait([0])
        // Second el_recv
        ..willCall('el_recv')
        ..willAwait([1])
        ..willReturn(const MontyNone());

      final stream = bridge.execute('loop');
      final sub = stream.listen((_) {});

      // Wait for first recv.
      await _until(() => plugin.isWaiting);
      plugin.dispatch({'cycle': 1});

      // Wait for second recv.
      await _until(() => plugin.isWaiting);
      plugin.dispatch({'cycle': 2});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(plugin.channelState, const EventLoopCompleted());

      // Both resolves should have the correct events.
      final answers = _returnAnswers(fake);
      expect(answers, hasLength(2));
      final first = _dart(answers[0])! as Map;
      expect(first['cycle'], 1);
      final second = _dart(answers[1])! as Map;
      expect(second['cycle'], 2);
    });
  });

  group('emit', () {
    test('stores value in lastEmitted', () async {
      fake
        ..willCall(
          'el_emit',
          args: [
            const MontyDict([
              (MontyString('type'), MontyString('counter')),
              (MontyString('value'), MontyInt(0)),
            ]),
          ],
        )
        ..willAwait([0])
        ..willReturn(const MontyNone());

      await bridge.execute('el_emit(value)').toList();

      expect(plugin.lastEmitted, {'type': 'counter', 'value': 0});
    });

    test('lastEmitted tracks most recent value', () async {
      fake
        ..willCall(
          'el_emit',
          args: [
            const MontyDict([(MontyString('version'), MontyInt(1))]),
          ],
        )
        ..willAwait([0])
        ..willCall(
          'el_emit',
          args: [
            const MontyDict([(MontyString('version'), MontyInt(2))]),
          ],
        )
        ..willAwait([1])
        ..willReturn(const MontyNone());

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
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willRaise('RuntimeError', message: 'kaboom');

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await _until(() => plugin.isWaiting);

        // Simulate the pending Completer being resolved with an error by
        // the bridge when the script errors — we dispatch to unblock the
        // fake's ResolveFutures step so the Complete(error) event can
        // flow through.
        plugin.dispatch({'type': 'unblock'});

        await sub.asFuture<void>();
        await sub.cancel();

        // Plugin should be completed, not stuck in waiting.
        expect(plugin.channelState, const EventLoopCompleted());

        // Verify a BridgeRunError was emitted.
        expect(events.whereType<BridgeRunError>(), isNotEmpty);
      },
    );

    test(
      'dispose while waiting completes with error',
      () async {
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willRaise(
            'RuntimeError',
            message: 'Bridge disposed while waiting for event',
          );

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await _until(() => plugin.isWaiting);

        // Dispose while waiting.
        await plugin.onDispose();
        expect(plugin.channelState, const EventLoopDisposed());

        // The execution stream should finish (possibly with an error event).
        await sub.asFuture<void>();
        await sub.cancel();
      },
    );
  });

  group('channelState transitions', () {
    test('idle -> executing -> completed', () async {
      expect(plugin.channelState, const EventLoopIdle());

      fake.willReturn(const MontyNone());

      final stream = bridge.execute('42');

      // Should be executing after execute() is called.
      expect(plugin.channelState, const EventLoopExecuting());

      await stream.toList();

      expect(plugin.channelState, const EventLoopCompleted());
    });

    test(
      'idle -> executing -> waiting -> executing -> completed',
      () async {
        expect(plugin.channelState, const EventLoopIdle());

        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willReturn(const MontyNone());

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});

        // Let it reach recv.
        await _until(() => plugin.isWaiting);
        expect(plugin.channelState, isA<EventLoopWaiting>());

        plugin.dispatch({'type': 'click'});
        expect(plugin.channelState, const EventLoopExecuting());

        await sub.asFuture<void>();
        await sub.cancel();
        expect(plugin.channelState, const EventLoopCompleted());
      },
    );

    test('disposed state after onDispose()', () async {
      await plugin.onDispose();
      expect(plugin.channelState, const EventLoopDisposed());
    });
  });

  group('signals', () {
    test(
      'channelStateSignal reflects transitions through waiting',
      () async {
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willReturn(const MontyNone());

        final states = <EventLoopState>[];
        final cleanup = effect(
          () => states.add(plugin.channelStateSignal.value),
        );

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});

        await _until(() => plugin.isWaiting);

        plugin.dispatch({'type': 'tap'});

        await sub.asFuture<void>();
        await sub.cancel();
        cleanup();

        // States collected: idle (initial effect run), executing, waiting,
        // executing (dispatch), completed.
        expect(states, [
          isA<EventLoopIdle>(),
          isA<EventLoopExecuting>(),
          isA<EventLoopWaiting>(),
          isA<EventLoopExecuting>(),
          isA<EventLoopCompleted>(),
        ]);
      },
    );

    test(
      'lastEmittedSignal updates when el_emit is called',
      () async {
        fake
          ..willCall(
            'el_emit',
            args: [
              const MontyDict([(MontyString('type'), MontyString('label'))]),
            ],
          )
          ..willAwait([0])
          ..willReturn(const MontyNone());

        final emitted = <Map<String, dynamic>?>[];
        final cleanup = effect(
          () => emitted.add(plugin.lastEmittedSignal.value),
        );

        await bridge.execute('el_emit(value)').toList();
        cleanup();

        // Initial null + one update from emit.
        expect(emitted.where((e) => e != null), hasLength(1));
        expect(emitted.last?['type'], 'label');
      },
    );
  });

  group('host function registration', () {
    test('el_recv and el_emit are registered', () {
      final names = bridge.schemas.map((s) => s.name).toList();
      expect(names, contains('el_recv'));
      expect(names, contains('el_emit'));
    });
  });

  group('execute error paths', () {
    test(
      'plugin state stays idle when execute() throws StateError',

      () {
        bridge.dispose();
        expect(plugin.channelState, const EventLoopIdle());
        expect(() => bridge.execute('1'), throwsStateError);
        // onAttach was called but _wrapStream was never called — state remains
        // idle
        expect(plugin.channelState, const EventLoopIdle());
      },
    );

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
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willRaise('RuntimeError', message: 'script died unexpectedly');

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        // Let bridge reach recv.
        await _until(() => plugin.isWaiting);

        // Dispatch event to unblock the completer and let the error flow.
        plugin.dispatch({'type': 'trigger'});

        await sub.asFuture<void>();
        await sub.cancel();

        // Plugin should be completed (error event was emitted).
        expect(plugin.channelState, const EventLoopCompleted());
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('script died unexpectedly'));
      },
    );

    test(
      'run error while waiting cleans up orphaned completer',
      () async {
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willRaise('RuntimeError', message: 'script crashed');

        final events = <BridgeEvent>[];
        final stream = bridge.execute('el_recv()');
        final sub = stream.listen(events.add);

        await _until(() => plugin.isWaiting);

        // Dispatch to unblock, then the error Complete flows through.
        plugin.dispatch({'type': 'unblock'});

        await sub.asFuture<void>();
        await sub.cancel();

        // The stream.map handler should have completed the orphaned
        // completer with an error and set state to completed.
        expect(plugin.channelState, const EventLoopCompleted());
        final errors = events.whereType<BridgeRunError>().toList();
        expect(errors, hasLength(1));
        expect(errors.first.message, contains('script crashed'));
      },
    );
  });

  group('sync answer (unmarked handler)', () {
    test('el_recv works when answered in place', () async {
      final syncMock = FakeMontySession();
      final syncPlugin = EventLoopExtension();
      final syncBridge = SessionBridge(session: syncMock);
      await syncPlugin.onAttach(syncBridge);
      // Each function registered as an unmarked (sync-mode) copy, so the
      // call is answered in place rather than through the futures protocol.
      for (final fn in syncPlugin.functions) {
        syncBridge.register(
          HostFunction(
            schema: fn.schema,
            ffiHandler: fn.ffiHandler,
            wasmHandler: fn.wasmHandler,
          ),
          category: syncPlugin.namespace,
        );
      }
      addTearDown(() async {
        await syncPlugin.onDispose();
        syncBridge.dispose();
      });

      syncMock
        ..willCall('el_recv')
        ..willReturn(const MontyNone());

      final stream = syncBridge.execute('el_recv()');
      final sub = stream.listen((_) {});

      // Let it reach the handler.
      await _until(() => syncPlugin.isWaiting);

      syncPlugin.dispatch({'type': 'sync_click'});

      await sub.asFuture<void>();
      await sub.cancel();

      expect(syncPlugin.channelState, const EventLoopCompleted());
      // An unmarked handler is answered in place, not through a future.
      final answers = _returnAnswers(syncMock);
      expect(answers, hasLength(1));
      expect(_dart(answers.single), isA<Map<String, Object?>>());
      final result = _dart(answers.single)! as Map;
      expect(result['type'], 'sync_click');
    });
  });

  group('lifecycle and ownership', () {
    test(
      'dispatch throws StateError when plugin is completed',
      () async {
        fake.willReturn(const MontyNone());

        await bridge.execute('code').toList();
        expect(plugin.channelState, const EventLoopCompleted());

        expect(
          () => plugin.dispatch({'type': 'too_late'}),
          throwsStateError,
        );
      },
    );

    test(
      'dispatch is allowed after re-execute following completion',
      () async {
        // First execution completes.
        fake.willReturn(const MontyNone());

        await bridge.execute('code').toList();
        expect(plugin.channelState, const EventLoopCompleted());

        // Second execution starts — state transitions back to executing.
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willReturn(const MontyNone());

        final stream = bridge.execute('el_recv()');
        final sub = stream.listen((_) {});
        await _until(() => plugin.isWaiting);

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
      // an exception answer to the call. This test verifies that
      // invariant end-to-end.
      fake
        ..willCall(
          'el_emit',
          args: [
            const MontyDict([(MontyString('type'), MontyString('event'))]),
          ],
        )
        ..willAwait([0])
        ..willReturn(const MontyNone());

      final events = await bridge.execute('el_emit(value)').toList();

      expect(events.whereType<BridgeRunFinished>(), isNotEmpty);
      expect(events.whereType<BridgeRunError>(), isEmpty);
      expect(
        [
          for (final a in fake.answers)
            if (a.answer is ExternalException) a,
        ],
        isEmpty,
      );
    });
  });

  group('bridge locking regression', () {
    test(
      'wrapper exception resets _isExecuting immediately (not after _run)',
      () async {
        // Regression: without the try-catch in SessionBridge.execute(),
        // a synchronously-throwing wrapper leaves _isExecuting = true until
        // _run's whenComplete fires. The very next execute() call (before any
        // microtask yields) would throw 'Bridge is already executing' even
        // though the first call failed before producing a valid stream.
        final lockMock = FakeMontySession();
        final lockBridge = SessionBridge(session: lockMock);
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
          ..willReturn(const MontyNone())
          ..willReturn(const MontyNone());

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
        // child", so child bridges get no EventLoopExtension. Python code
        // inside a child sandbox that calls el_recv() or el_emit() would
        // raise NameError because those host functions were never registered.
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
        expect(childPlugin.channelState, const EventLoopIdle());

        // Disposing the child must not affect the parent.
        await childPlugin.onDispose();
        expect(plugin.channelState, isNot(const EventLoopDisposed()));
      },
    );
  });

  group('ExtensionCoordinator integration', () {
    test(
      'ExtensionCoordinator.attachTo wires stream wrapper',
      () async {
        final mock2 = FakeMontySession()..willReturn(const MontyNone());
        final plugin2 = EventLoopExtension();
        final registry = ExtensionCoordinator()..register(plugin2);
        final bridge2 = SessionBridge(session: mock2);
        await registry.attachTo(bridge2);

        final events = await bridge2.execute('pass').toList();
        expect(events.whereType<BridgeRunFinished>(), hasLength(1));
        expect(plugin2.channelState, const EventLoopCompleted());

        await registry.disposeAll();
        bridge2.dispose();
      },
    );
  });

  group('D1 contract', () {
    test(
      'dispatch while waiting resumes and clears isWaiting at once',
      () async {
        fake
          ..willCall('el_recv')
          ..willAwait([0])
          ..willReturn(const MontyNone());
        final done = bridge.execute('el_recv()').toList();
        await _until(() => plugin.isWaiting);

        plugin.dispatch({'k': 1});

        expect(plugin.isWaiting, isFalse);
        await done;
        expect(_dart(_returnAnswers(fake).single), {'k': 1});
      },
    );

    test('a new execution after a completed one discards the queue', () async {
      final gate = Completer<void>();
      fake
        // First feed: holds, then finishes without reading the queue.
        ..willHold(gate.future)
        ..willReturn(const MontyNone())
        // Second feed: waits at el_recv.
        ..willCall('el_recv')
        ..willAwait([0])
        ..willReturn(const MontyNone());
      final first = bridge.execute('first').toList();
      await _until(() => plugin.channelState is EventLoopExecuting);
      plugin.dispatch({'stale': true});
      gate.complete();
      await first;

      final second = bridge.execute('el_recv()').toList();
      await _until(() => plugin.isWaiting);
      plugin.dispatch({'fresh': true});
      await second;

      expect(_dart(_returnAnswers(fake).single), {'fresh': true});
    });

    test('namespace is el, with el_recv() and el_emit(value: map)', () {
      expect(plugin.namespace, 'el');
      final [recv, emit] = plugin.functions;
      expect(recv.schema.name, 'el_recv');
      expect(recv.schema.params, isEmpty);
      expect(recv.dispatch, DispatchMode.future);
      expect(emit.schema.name, 'el_emit');
      final [value] = emit.schema.params;
      expect(
        (value.name, value.type, value.isRequired),
        ('value', HostParamType.map, true),
      );
      expect(emit.dispatch, DispatchMode.future);
    });

    test('lastEmitted is null until the first el_emit', () {
      expect(plugin.lastEmitted, isNull);
      expect(plugin.lastEmittedSignal.value, isNull);
    });

    test('childPolicy is clone, and a child shares no queue', () async {
      expect(plugin.childPolicy, ChildPolicy.clone);
      plugin.dispatch({'parent': 1});
      final child =
          plugin.createChildInstance(const ChildSpawnContext(childId: 1))
              as EventLoopExtension;
      addTearDown(child.onDispose);
      final childFake = FakeMontySession()
        ..willCall('el_recv')
        ..willAwait([0])
        ..willReturn(const MontyNone());
      final childBridge = SessionBridge(session: childFake);
      addTearDown(childBridge.dispose);
      await child.onAttach(childBridge);
      for (final fn in child.functions) {
        childBridge.register(fn, category: child.namespace);
      }

      final done = childBridge.execute('el_recv()').toList();
      // The parent's queued value does not reach the child.
      await _until(() => child.isWaiting);
      child.dispatch({'child': 1});
      await done;

      expect(_dart(_returnAnswers(childFake).single), {'child': 1});
      expect(child.lastEmitted, isNull);
    });

    test('onDispose is idempotent and disposes both signals', () async {
      await plugin.onDispose();
      await plugin.onDispose();

      expect(plugin.channelState, const EventLoopDisposed());
      expect(plugin.lastEmittedSignal.disposed, isTrue);
      expect(plugin.channelStateSignal.disposed, isTrue);
    });

    test('a runtime whose extension is disposed fails its execution', () async {
      final ext = EventLoopExtension();
      final runtime = await startRuntimeWith(
        checkout: ({limits}) async => FakeMontySession(),
        extensions: [ext],
      );
      addTearDown(runtime.dispose);
      await runtime.invoke('el_emit', {'value': <String, Object?>{}});
      await ext.onDispose();

      await expectLater(
        runtime.execute('1').result,
        throwsA(isA<StateError>()),
      );
    });
  });
}
