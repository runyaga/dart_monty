@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  test('two children borrow an inherited extension', () async {
    final pool = await childContractPool();
    final parentBridgeFuture = childContractBridge(pool);
    final parentBridge = await parentBridgeFuture;
    final borrowed = ChildContractExtension(
      'borrowed',
      childPolicy: ChildPolicy.inherit,
    );
    final parent = ExtensionCoordinator()..register(borrowed);
    await parent.attachTo(parentBridge);
    final ownerLogger = borrowed.logger;
    final children = <ExtensionCoordinator>[];
    final bridges = <MontyBridge>[];
    for (var id = 0; id < 2; id++) {
      final bridgeFuture = childContractBridge(pool);
      final bridge = await bridgeFuture;
      bridges.add(bridge);
      children.add(
        await parent.spawnChild(
          context: ChildSpawnContext(childId: id),
          bridge: bridge,
        ),
      );
      expect(coordinatorOf(borrowed), same(parent));
      expect(borrowed.logger, same(ownerLogger));
    }
    final [firstChild, secondChild] = children;
    final [_, secondBridge] = bridges;
    await firstChild.disposeAll();
    expect(borrowed.disposals, 0);
    expect(
      await secondBridge.invokeHostFunction('borrowed_id', {}),
      const MontyInt(-1),
    );
    expect(
      await parentBridge.invokeHostFunction('borrowed_id', {}),
      const MontyInt(-1),
    );
    var disposed = false;
    Future<void> disposeParent() async {
      await parent.disposeAll();
      disposed = true;
    }

    final disposing = disposeParent();
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    expect(borrowed.disposals, 0);
    await secondChild.disposeAll();
    await disposing;
    expect(borrowed.disposals, 1);
    await parent.disposeAll();
    expect(borrowed.disposals, 1);
  });

  // Clone and exclude ownership are independent of borrowed instance leases.
  test('children own their clones and skip excluded extensions', () async {
    final pool = await childContractPool();
    final parentBridgeFuture = childContractBridge(pool);
    final parentBridge = await parentBridgeFuture;
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
      final bridgeFuture = childContractBridge(pool);
      final bridge = await bridgeFuture;
      bridges.add(bridge);
      final child = await parent.spawnChild(
        context: ChildSpawnContext(childId: id),
        bridge: bridge,
      );
      children.add(child);
      expect(bridge.schemas.map((s) => s.name), ['owned_id', 'help']);
      final [..., clone] = cloneable.clones;
      expect(clone, isNot(same(cloneable)));
      expect(child.extensions, [same(clone)]);
      expect(coordinatorOf(clone), same(child));
    }
    final [firstChild, secondChild] = children;
    final [firstClone, secondClone] = cloneable.clones;
    final [_, secondBridge] = bridges;
    expect(firstClone, isNot(same(secondClone)));
    expect(excluded.clones, isEmpty);
    await firstChild.disposeAll();
    expect(firstClone.disposals, 1);
    expect(secondClone.disposals, 0);
    expect(cloneable.disposals, 0);
    expect(
      await secondBridge.invokeHostFunction('owned_id', {}),
      const MontyInt(1),
    );
    expect(
      await parentBridge.invokeHostFunction('owned_id', {}),
      const MontyInt(-1),
    );
    await secondChild.disposeAll();
    await parent.disposeAll();
    expect(cloneable.clones.map((e) => e.disposals), [1, 1]);
    expect(cloneable.disposals, 1);
    expect(excluded.disposals, 1);
  });
}
