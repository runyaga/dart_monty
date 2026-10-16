// Each bridge factory call must acquire a distinct session. Collection
// access deliberately fails fast when an expected event/clone is absent.
// ignore_for_file: prefer-moving-to-variable, avoid-unsafe-collection-methods
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  // Preparation subset of G2. The coordinator can forward a supplied context;
  // runtime-owned child checkout and /work selection remain D5-A gaps.
  test('D5-context-coordinator-isolation', () async {
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
    expect(extension.clones.single.context, same(context));
    expect(childBridge.schemas.map((s) => s.name), ['probe_id', 'help']);
    for (final name in ['parent_global', 'raw_parent()']) {
      final events = await childBridge.execute(name).toList();
      expect(events.last, isA<BridgeRunError>());
      expect(
        (events.last as BridgeRunError).exception?.exception.excType,
        'NameError',
      );
    }
    final events = await childBridge
        .execute("import os\n[probe_id(), os.getenv('D5_ORIGIN')]")
        .toList();
    expect(
      (events.last as BridgeRunFinished).montyValue,
      const MontyList([MontyInt(7), MontyString('execution')]),
    );
  });
}
