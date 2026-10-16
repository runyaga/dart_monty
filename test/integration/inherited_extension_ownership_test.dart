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
  // Borrowed instances/leases remain a gap. Clone and exclude already work
  // through the internal coordinator, independently of sandbox checkout.
  test('D5-clone-exclude', () async {
    final pool = await childContractPool();
    final parentBridge = await childContractBridge(pool);
    final cloneable = ChildContractExtension('owned');
    final excluded = ChildContractExtension(
      'excluded',
      childPolicy: ChildPolicy.exclude,
    );
    final parent = ExtensionCoordinator()
      ..register(cloneable)
      ..register(excluded);
    await parent.attachTo(parentBridge);
    final children = <ExtensionCoordinator>[];
    final bridges = <MontyBridge>[];
    for (var id = 0; id < 2; id++) {
      final bridge = await childContractBridge(pool);
      bridges.add(bridge);
      children.add(
        await parent.spawnChild(
          context: ChildSpawnContext(childId: id),
          bridge: bridge,
        ),
      );
      expect(bridge.schemas.map((s) => s.name), ['owned_id', 'help']);
      expect(cloneable.clones[id], isNot(same(cloneable)));
      expect(children[id].extensions, [same(cloneable.clones[id])]);
      expect(coordinatorOf(cloneable.clones[id]), same(children[id]));
    }
    expect(cloneable.clones.first, isNot(same(cloneable.clones[1])));
    expect(excluded.clones, isEmpty);
    await children.first.disposeAll();
    expect(cloneable.clones.first.disposals, 1);
    expect(cloneable.clones[1].disposals, 0);
    expect(cloneable.disposals, 0);
    expect(
      await bridges[1].invokeHostFunction('owned_id', {}),
      const MontyInt(1),
    );
    expect(
      await parentBridge.invokeHostFunction('owned_id', {}),
      const MontyInt(-1),
    );
    await children[1].disposeAll();
    await parent.disposeAll();
    expect(cloneable.clones.map((e) => e.disposals), [1, 1]);
    expect(cloneable.disposals, 1);
    expect(excluded.disposals, 1);
  });
}
