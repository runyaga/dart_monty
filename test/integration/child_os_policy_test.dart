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
  test('a system child bypasses inherited OS callbacks', () async {
    var calls = 0;
    final runtime = await MontyRuntime.start(
      pool: await childContractPool(),
      extensions: [SandboxExtension()],
      os: (_, _, _) {
        calls++;
        throw StateError('System policy must not call this handler');
      },
    );
    addTearDown(runtime.dispose);
    // A normal inherited non-filesystem callback is demonstrably installed.
    final probe = await spawnChild(runtime, "import os; os.getenv('D5')");
    await expectLater(awaitChild(runtime, probe), throwsA(isA<Exception>()));
    expect(calls, 1);
    final result =
        await awaitChild(runtime, await spawnChild(runtime, _script))
            as MontyList;
    final [MontyFloat first, MontyFloat second, ...] = result.items;
    expect(first.value, greaterThan(0));
    expect(second.value, inInclusiveRange(0, 1));
    expect(calls, 1);
  });

  // Also exercise inherited callbacks through a directly attached coordinator.
  test('a system child coordinator bypasses inherited OS callbacks', () async {
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
    expect(probe.lastOrNull, isA<BridgeRunError>());
    expect(calls, 1);
    final events = await bridge.execute(_script).toList();
    final BridgeRunFinished(:montyValue) = events.lastOrNull;
    final value = montyValue! as MontyList;
    final [MontyFloat first, MontyFloat second, ...] = value.items;
    expect(first.value, greaterThan(0));
    expect(second.value, inInclusiveRange(0, 1));
    expect(calls, 1);
    expect(events.whereType<BridgeOsCallStart>(), isEmpty);
  });

  test('a direct child OS policy is authoritative', () async {
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
          final [MontyInt(value: count)] = args;

          return MontyBytes(Uint8List.fromList(List.filled(count, entropy)));
        }
        throw StateError('unexpected OS call $name');
      });
      final events = await bridge.execute(_script).toList();
      expect(events.lastOrNull, isA<BridgeRunFinished>(), reason: '$events');
      final BridgeRunFinished(:montyValue) = events.lastOrNull;
      final value = montyValue! as MontyList;
      final [MontyFloat first, MontyFloat second, ...] = value.items;
      expect(first, const MontyFloat(1234.5));
      final draw = second.value;
      expect(draw, inInclusiveRange(0, 1));
      draws.add(draw);
      expect(calls, ['time.time', 'os.urandom']);
      expect(events.whereType<BridgeOsCallStart>(), hasLength(2));
      bridge.dispose();
      await session.close();
    }
    // Host entropy is authoritative: equal bytes reproduce the stream, and
    // changing only those bytes changes the result.
    final [first, second, third] = draws;
    expect(second, first);
    expect(third, isNot(first));
  });
}
