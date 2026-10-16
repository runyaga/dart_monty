@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:struct_log/struct_log.dart';
import 'package:test/test.dart';

import '_worker.dart';
import 'lifecycle_probe_extension.dart';

void main() {
  late Monty pool;
  late MontyBridge bridge;
  late ExtensionCoordinator coordinator;
  late LifecycleProbeExtension probe;

  setUpAll(() async => pool = await startTestPool(maxProcesses: 3));
  tearDownAll(() => pool.close());

  Future<MontyBridge> createBridge() async {
    final session = await pool.checkout();
    addTearDown(session.close);
    final result = MontyBridge(session: session);
    addTearDown(result.dispose);

    return result;
  }

  setUp(() async {
    bridge = await createBridge();
    probe = LifecycleProbeExtension();
    coordinator = ExtensionCoordinator()..register(probe);
    addTearDown(coordinator.disposeAll);
    await coordinator.attachTo(bridge);
  });

  test(
    'attach registers public extension functions and their category',
    () async {
      expect(probe.attachedTo, same(bridge));
      expect(
        bridge.schemasByCategory['lifecycle']!.map((schema) => schema.name),
        containsAll(['lifecycle_store', 'lifecycle_read']),
      );
      expect(await _run(bridge, 'lifecycle_store(42)'), 42);
      expect(probe.stores, 1);
    },
  );

  test(
    'unregister removes the function from Python and introspection',
    () async {
      expect(await _run(bridge, 'lifecycle_store(7)'), 7);
      bridge.unregister('lifecycle_store');
      expect(
        bridge.schemas.map((schema) => schema.name),
        isNot(contains('lifecycle_store')),
      );
      final events = await bridge.execute('lifecycle_store(8)').toList();
      expect(
        _only(events.whereType<BridgeRunError>()).message,
        contains('NameError'),
      );
      expect(probe.stores, 1);
      expect(await _run(bridge, 'lifecycle_read()'), 7);
    },
  );

  test('register restores an unregistered extension function', () async {
    expect(await _run(bridge, 'lifecycle_store(1)'), 1);
    bridge
      ..unregister('lifecycle_store')
      ..register(probe.functions.firstOrNull!, category: probe.namespace);
    expect(await _run(bridge, 'lifecycle_store(2)'), 2);
    expect(probe.stores, 2);
  });

  test('direct invocation and Python share the same extension state', () async {
    expect(await _run(bridge, 'lifecycle_store("python")'), 'python');
    expect(await bridge.invokeHostFunction('lifecycle_read', {}), 'python');
    expect(
      await bridge.invokeHostFunction('lifecycle_store', {'value': 'dart'}),
      'dart',
    );
    expect(await _run(bridge, 'lifecycle_read()'), 'dart');
    expect(probe.stores, 2);
  });

  test('direct invocation rejects an unregistered function', () async {
    expect(await _run(bridge, 'lifecycle_store(3)'), 3);
    bridge.unregister('lifecycle_store');
    expect(
      () => bridge.invokeHostFunction('lifecycle_store', {'value': 4}),
      throwsArgumentError,
    );
    expect(await _run(bridge, 'lifecycle_read()'), 3);
  });

  test(
    'emitText is correlated and ordered within a Python host call',
    () async {
      final events = await bridge
          .execute('lifecycle_emit("progress")')
          .toList();
      final start = _only(events.whereType<BridgeFunctionCallStart>());
      final emitted = _only(events.whereType<BridgeFunctionEmit>());
      final result = _only(events.whereType<BridgeFunctionCallResult>());
      expect(emitted.text, 'progress');
      expect(emitted.callId, start.callId);
      expect(result.callId, start.callId);
      final emittedIndex = events.indexOf(emitted);
      expect(emittedIndex, greaterThan(events.indexOf(start)));
      expect(emittedIndex, lessThan(events.indexOf(result)));
      expect(_only(events.whereType<BridgeRunFinished>()).value, 8);
    },
  );

  test('direct invocation delivers text before completing', () async {
    expect(await _run(bridge, 'lifecycle_emit("python")'), 6);
    final events = <BridgeEvent>[];
    final result = await bridge.invokeHostFunction(
      'lifecycle_emit',
      {'text': 'dart'},
      onEvent: events.add,
    );
    expect(result, 4);
    final emitted = _only(events.whereType<BridgeFunctionEmit>());
    expect(emitted.text, 'dart');
    expect(emitted.callId, 'lifecycle_emit');
  });

  test(
    'an event callback failure does not fail the handler or next run',
    () async {
      final result = await bridge.invokeHostFunction(
        'lifecycle_emit',
        {'text': 'dart'},
        onEvent: (_) => throw StateError('sink failed'),
      );
      expect(result, 4);
      expect(await _run(bridge, 'lifecycle_emit("still working")'), 13);
    },
  );

  test('required any accepts Python None as a supplied value', () async {
    expect(await _run(bridge, 'lifecycle_store(None)'), isNull);
    expect(probe.stores, 1);
    expect(await bridge.invokeHostFunction('lifecycle_read', {}), isNull);
  });

  test(
    'missing required value fails before mutating extension state',
    () async {
      expect(await _run(bridge, 'lifecycle_store(9)'), 9);
      final events = await bridge.execute('lifecycle_store()').toList();
      expect(
        _only(events.whereType<BridgeRunError>()).message,
        contains('Required parameter "value" is missing'),
      );
      expect(probe.stores, 1);
      expect(await _run(bridge, 'lifecycle_read()'), 9);
    },
  );

  test('HostParam.validate accepts an integer arriving from Python', () async {
    expect(await _run(bridge, 'lifecycle_checked(42) + 1'), 43);
  });

  test(
    'HostParam.validate rejects a Python float without truncation',
    () async {
      final events = await bridge.execute('lifecycle_checked(1.5)').toList();
      expect(
        _only(events.whereType<BridgeRunError>()).message,
        contains('expected int'),
      );
      expect(await _run(bridge, 'lifecycle_checked(2)'), 2);
    },
  );

  test(
    'createChildInstance returns fresh state attachable to a real session',
    () async {
      expect(await _run(bridge, 'lifecycle_store("parent")'), 'parent');
      const context = ChildSpawnContext(
        childId: 7,
        workingDirectory: '/child/7',
      );
      final clone = probe.createChildInstance(context);
      final childBridge = await createBridge();
      final childCoordinator = ExtensionCoordinator()..register(clone);
      addTearDown(childCoordinator.disposeAll);
      await childCoordinator.attachTo(childBridge);
      expect(clone, isNot(same(probe)));
      expect(clone.spawnContext, same(context));
      expect(clone.attachedTo, same(childBridge));
      expect(await _run(childBridge, 'lifecycle_read()'), isNull);
      expect(await _run(childBridge, 'lifecycle_store("child")'), 'child');
      expect(await _run(bridge, 'lifecycle_read()'), 'parent');
    },
  );

  test('spawnChild clones and child disposal leaves parent usable', () async {
    expect(await _run(bridge, 'lifecycle_store("parent")'), 'parent');
    final childBridge = await createBridge();
    const context = ChildSpawnContext(childId: 8);
    final childCoordinator = await coordinator.spawnChild(
      context: context,
      bridge: childBridge,
    );
    addTearDown(childCoordinator.disposeAll);
    final clone = _only(
      childCoordinator.extensions.whereType<LifecycleProbeExtension>(),
    );
    expect(clone, isNot(same(probe)));
    expect(clone.spawnContext, same(context));
    expect(await _run(childBridge, 'lifecycle_store("child")'), 'child');
    await childCoordinator.disposeAll();
    expect(clone.disposals, 1);
    expect(clone.value, isNull);
    expect(probe.disposals, 0);
    expect(await _run(bridge, 'lifecycle_read()'), 'parent');
  });

  test('disposeAll releases attached extension state idempotently', () async {
    expect(await _run(bridge, 'lifecycle_store(10)'), 10);
    await coordinator.disposeAll();
    await coordinator.disposeAll();
    expect(probe.disposals, 1);
    expect(probe.value, isNull);
    expect(probe.attachedTo, isNull);
  });

  test('runtime disposal invokes extension cleanup exactly once', () async {
    final ownedProbe = LifecycleProbeExtension();
    final runtime = await MontyRuntime.start(
      pool: pool,
      extensions: [ownedProbe],
    );
    addTearDown(runtime.dispose);
    expect((await runtime.execute('lifecycle_store(11)').result).dartValue, 11);
    await runtime.dispose();
    await runtime.dispose();
    expect(ownedProbe.disposals, 1);
    expect(ownedProbe.value, isNull);
    expect(ownedProbe.attachedTo, isNull);
    expect(() => runtime.execute('lifecycle_read()'), throwsStateError);
  });

  for (final level in [
    LogLevel.trace,
    LogLevel.debug,
    LogLevel.info,
    LogLevel.warning,
    LogLevel.error,
  ]) {
    test(
      'Python handler emits a scoped ${level.name} log with attributes',
      () async {
        final sink = MemorySink();
        final manager = LogManager.instance;
        final previousLevel = manager.minimumLevel;
        manager
          ..addSink(sink)
          ..minimumLevel = LogLevel.trace;
        addTearDown(() {
          manager
            ..removeSink(sink)
            ..minimumLevel = previousLevel;
        });
        expect(
          await _run(bridge, 'lifecycle_log("${level.name}")'),
          level.name,
        );
        final record = _only(
          sink.records.where((entry) => entry.message == 'probe log'),
        );
        expect(record.level, level);
        expect(record.loggerName, 'monty.lifecycle.handler');
        expect(record.attributes['level'], level.name);
      },
    );
  }

  group('event loop with a real session', () {
    late EventLoopExtension loop;

    setUp(() async {
      loop = EventLoopExtension();
      final loopCoordinator = ExtensionCoordinator()..register(loop);
      addTearDown(loopCoordinator.disposeAll);
      await loopCoordinator.attachTo(bridge, enableIntrospection: false);
    });

    test('pre-dispatched events reach Python in FIFO order', () async {
      loop
        ..dispatch({'value': 1})
        ..dispatch({'value': 2});
      expect(
        await _run(bridge, '[await el_recv(), await el_recv()]'),
        [
          {'value': 1},
          {'value': 2},
        ],
      );
      expect(loop.isWaiting, isFalse);
    });

    test(
      'dispatch resumes a waiting Python coroutine and emit returns its data',
      () async {
        final result = _run(
          bridge,
          'event = await el_recv()\nawait el_emit(event)\nevent',
        );
        await _untilWaiting(loop);
        loop.dispatch({'value': 42});
        expect(await result, {'value': 42});
        expect(loop.lastEmitted, {'value': 42});
        expect(loop.isWaiting, isFalse);
      },
    );

    test(
      'dispatch rejects completed runs and accepts a new waiting run',
      () async {
        expect(await _run(bridge, 'lifecycle_store(1)'), 1);
        expect(() => loop.dispatch({'stale': true}), throwsStateError);
        final result = _run(bridge, 'await el_recv()');
        await _untilWaiting(loop);
        loop.dispatch({'fresh': true});
        expect(await result, {'fresh': true});
      },
    );
  });
}

Future<Object?> _run(MontyBridge bridge, String code) async {
  final events = await bridge.execute(code).toList();
  expect(events.whereType<BridgeRunError>(), isEmpty);

  return _only(events.whereType<BridgeRunFinished>()).value;
}

Future<void> _untilWaiting(EventLoopExtension loop) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!loop.isWaiting && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(loop.isWaiting, isTrue, reason: 'Python must reach el_recv');
}

T _only<T extends Object>(Iterable<T> values) {
  expect(values, hasLength(1));

  return values.singleOrNull!;
}
