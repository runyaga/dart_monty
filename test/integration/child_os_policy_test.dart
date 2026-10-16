// Each bridge factory call must acquire a distinct session. Collection
// access deliberately fails fast when an expected event/clone is absent.
// ignore_for_file: prefer-moving-to-variable, avoid-unsafe-collection-methods
@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_child_contract.dart';

const _script = 'import time, random\n[time.time(), random.random()]';

void main() {
  // G11 preparation: a manually checked-out session with inherited callbacks.
  // The ordinary SandboxExtension checkout itself is still unimplemented.
  test('D5-system-child-coordinator', () async {
    final pool = await childContractPool();
    final parent = ExtensionCoordinator();
    addTearDown(parent.disposeAll);
    var calls = 0;
    await parent.attachTo(
      await childContractBridge(pool),
      baseOs: (_, _, _) {
        calls++;
        throw StateError('System policy must not call this handler');
      },
    );
    final bridge = await childContractBridge(pool);
    final child = await parent.spawnChild(
      context: const ChildSpawnContext(childId: 1),
      bridge: bridge,
    );
    addTearDown(child.disposeAll);
    // Prove the callback really was inherited before testing policy bypass.
    final probe = await bridge.execute("import os\nos.getenv('D5')").toList();
    expect(probe.last, isA<BridgeRunError>());
    expect(calls, 1);
    final events = await bridge.execute(_script).toList();
    final value = (events.last as BridgeRunFinished).montyValue! as MontyList;
    expect((value.items.first as MontyFloat).value, greaterThan(0));
    expect((value.items[1] as MontyFloat).value, inInclusiveRange(0, 1));
    expect(calls, 1);
    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
  });

  test('D5-direct-authoritative', () async {
    final pool = await childContractPool();
    final draws = <double>[];
    for (final entropy in [0, 0, 1]) {
      final session = await pool.checkout(
        osPolicy: const OsPolicy(
          datetime: 'call_host',
          randomStart: 'call_host',
        ),
      );
      addTearDown(session.close);
      final bridge = MontyBridge(session: session);
      addTearDown(bridge.dispose);
      final calls = <String>[];
      bridge.registerOs((name, args, kwargs) {
        calls.add(name);
        if (name == 'time.time') return const MontyFloat(1234.5);
        if (name == 'os.urandom') {
          final count = (args.single as MontyInt).value;

          return MontyBytes(Uint8List.fromList(List.filled(count, entropy)));
        }
        throw StateError('unexpected OS call $name');
      });
      final events = await bridge.execute(_script).toList();
      expect(events.last, isA<BridgeRunFinished>(), reason: '$events');
      final value = (events.last as BridgeRunFinished).montyValue! as MontyList;
      expect(value.items.first, const MontyFloat(1234.5));
      final draw = (value.items[1] as MontyFloat).value;
      expect(draw, inInclusiveRange(0, 1));
      draws.add(draw);
      expect(calls, ['time.time', 'os.urandom']);
      expect(events.whereType<BridgeOsCallStart>(), hasLength(2));
      bridge.dispose();
      await session.close();
    }
    // Host entropy is authoritative: equal bytes reproduce the stream, and
    // changing only those bytes changes the result.
    expect(draws[1], draws.first);
    expect(draws[2], isNot(draws.first));
  });
}
