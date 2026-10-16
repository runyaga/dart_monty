// Each bridge factory call must acquire a distinct session. Collection
// access deliberately fails fast when an expected event/clone is absent.
// ignore_for_file: prefer-moving-to-variable, avoid-unsafe-collection-methods
@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

void main() {
  // G6's coordinator already attempts every extension disposal. This does
  // not claim that sandbox terminal cleanup attempts every resource close.
  test('D5-dispose-throws-coordinator', () async {
    final pool = await childContractPool();
    final bridge = await childContractBridge(pool);
    final first = ChildContractExtension('first');
    final throwing = ChildContractExtension('throwing', throwOnDispose: true);
    final last = ChildContractExtension('last');
    final parent = ExtensionCoordinator()
      ..register(first)
      ..register(throwing)
      ..register(last);
    await parent.attachTo(bridge);
    final child = await parent.spawnChild(
      context: const ChildSpawnContext(childId: 1),
      bridge: await childContractBridge(pool),
    );
    await expectLater(
      child.disposeAll(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'collected error',
          contains('dispose throwing'),
        ),
      ),
    );
    for (final extension in [first, throwing, last]) {
      expect(extension.clones.single.disposals, 1);
      expect(extension.disposals, 0);
    }
    await expectLater(parent.disposeAll(), throwsStateError);
    for (final extension in [first, throwing, last]) {
      expect(extension.disposals, 1);
    }
  });
}
