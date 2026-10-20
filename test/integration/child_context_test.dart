// Keep guest programs and historical case IDs intact.
// ignore_for_file: lines_longer_than_80_chars
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/runtime/runtime.dart' show startRuntimeWith;
import 'package:test/test.dart';

import '../src/_recording_session.dart';
import '_child_contract.dart';

void main() {
  test('a child checkout receives its parent context', () async {
    final pool = await childContractPool();
    final sessions = <RecordingSession>[];
    final extension = ChildContractExtension('probe');
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        final session = RecordingSession(await pool.checkout(limits: limits));
        sessions.add(session);

        return session;
      },
      extensions: [extension, SandboxExtension()],
    );
    addTearDown(runtime.dispose);
    runtime.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'raw_parent'),
        handler: (_, _) async => const MontyInt(9),
      ),
    );
    final run = runtime.execute(
      'parent_global = 17\nh = sandbox_spawn("import os; [os.getcwd(), probe_id()]")\nsandbox_await(h)',
    );
    final events = run.events.toList();
    expect(
      await run.result,
      const MontyList([MontyString('/work'), MontyInt(0)]),
    );
    expect(
      (await events)
          .whereType<BridgeChildEvent>()
          .map((e) => e.childHandle)
          .toSet(),
      {'0'},
    );
    expect(sessions, hasLength(2));
    expect(sessions.elementAtOrNull(1)?.feeds.singleOrNull?.cwd, '/work');
    expect(sessions.elementAtOrNull(1)?.closeCalls, 1);
    expect(extension.clones.singleOrNull?.context?.workingDirectory, '/work');
    for (final name in ['parent_global', 'raw_parent()']) {
      final handle = await spawnChild(runtime, name);
      await expectLater(
        awaitChild(runtime, handle),
        throwsA(predicate<Object>((e) => e.toString().contains('NameError'))),
      );
    }
  });

  test('a child sub-execution receives its context', () async {
    final pool = await childContractPool();
    final observed = <ResourceLimits?>[];
    final sessions = <RecordingSession>[];
    const selected = ResourceLimits(
      maxFeedDuration: Duration(seconds: 3),
      maxSuspensions: 7,
      gcInterval: 123,
    );
    final runtime = await startRuntimeWith(
      checkout: ({limits}) async {
        observed.add(limits);
        final session = RecordingSession(await pool.checkout(limits: limits));
        sessions.add(session);

        return session;
      },
      extensions: [
        _SubExtension(),
        SandboxExtension(childLimits: selected),
      ],
    );
    addTearDown(runtime.dispose);
    final handle = await spawnChild(runtime, 'nested_run()');
    expect(await awaitChild(runtime, handle), const MontyInt(42));
    expect(sessions, hasLength(3));
    final sameLimits = same(selected);
    expect(observed.elementAtOrNull(1), sameLimits);
    expect(observed.elementAtOrNull(2), sameLimits);
    expect(sessions.elementAtOrNull(1)?.closeCalls, 1);
    expect(sessions.elementAtOrNull(2)?.closeCalls, 1);
  });

  // Coordinator isolation complements the live checkout witness above.
  test('child coordinators isolate their context', () async {
    final pool = await childContractPool();
    final parentBridge = await childContractBridge(pool);
    final childBridge = await childContractBridge(pool);
    final extension = ChildContractExtension('probe');
    final parent = ExtensionCoordinator()..register(extension);
    addTearDown(parent.disposeAll);
    await parent.attachTo(
      parentBridge,
      baseOs: (_, _, _) => const MontyString('parent'),
    );
    parentBridge.register(
      HostFunction(
        schema: const HostFunctionSchema(name: 'raw_parent'),
        handler: (_, _) async => const MontyInt(99),
      ),
    );
    await parentBridge.execute('parent_global = 42').drain<void>();
    const context = ChildSpawnContext(childId: 7, workingDirectory: '/work');
    final child = await parent.spawnChild(
      context: context,
      bridge: childBridge,
      baseOs: (_, _, _) => const MontyString('execution'),
    );
    addTearDown(child.disposeAll);
    expect(extension.clones.singleOrNull?.context, same(context));
    expect(childBridge.schemas.map((s) => s.name), ['probe_id', 'help']);
    for (final name in ['parent_global', 'raw_parent()']) {
      final events = await childBridge.execute(name).toList();
      expect(events.lastOrNull, isA<BridgeRunError>());
      expect(
        (events.lastOrNull! as BridgeRunError).exception?.exception.excType,
        'NameError',
      );
    }
    final events = await childBridge
        .execute("import os\n[probe_id(), os.getenv('D5_ORIGIN')]")
        .toList();
    expect(
      (events.lastOrNull! as BridgeRunFinished).montyValue,
      const MontyList([MontyInt(7), MontyString('execution')]),
    );
  });
}

final class _SubExtension extends MontyExtension {
  @override
  String get namespace => 'nested';
  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;
  @override
  MontyExtension createChildInstance(ChildSpawnContext context) =>
      _SubExtension();
  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(name: 'nested_run'),
      handler: (_, ctx) => ctx.subExecute!('40 + 2'),
    ),
  ];
}
