@Tags(['integration'])
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty/monty_backend_spi.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

/// Integration tests for MessageBusPlugin parent↔child communication.
///
/// Run with:
/// ```bash
/// cd native && cargo build --release && cd ..
/// cd packages/dart_monty_bridge
/// DYLD_LIBRARY_PATH=../../native/target/release \
///   dart test --tags=integration --run-skipped \
///   test/integration/message_bus_integration_test.dart
/// ```
void main() {
  late NativeBindingsFfi bindings;

  setUpAll(() {
    bindings = NativeBindingsFfi();
  });

  MontyPlatform createPlatform() => MontyFfi(bindings: bindings);

  /// Executes [code] on a bridge and returns the final value or throws.
  Future<Object?> run(MontyBridge bridge, String code) async {
    Object? result;
    String? error;
    await for (final event in bridge.execute(code)) {
      if (event is BridgeRunFinished) {
        result = event.value;
      } else if (event is BridgeRunError) {
        error = event.message;
      }
    }
    if (error != null) throw Exception(error);
    return result;
  }

  String spawn(String childCode) => 'sandbox_spawn(code="$childCode")';

  MontyBridge createBridge() =>
      MontyBridge(platform: createPlatform(), useFutures: false);

  Future<MontyBridge> createBridgeWithMessageBus() async {
    final bridge = createBridge();
    final msgBus = MessageBusPlugin();
    final registry = ExtensionCoordinator()
      ..register(msgBus)
      ..register(
        SandboxPlugin(platformFactory: () async => createPlatform()),
      );
    await registry.attachTo(bridge);
    return bridge;
  }

  // ---------------------------------------------------------------------------
  // Test 1: Simple — parent sends, child receives and returns the value
  // ---------------------------------------------------------------------------

  test('parent sends message, child receives and returns it', () async {
    final bridge = await createBridgeWithMessageBus();

    // Child blocks on msg_recv until the parent sends, then returns the value.
    // useFutures: false on child bridges (#212) — direct call, no await.
    const childCode = r'msg_recv(name=\"inbox\")';

    final result = await run(
      bridge,
      'h = ${spawn(childCode)}\n'
      'msg_send(name="inbox", message={"greeting": "hello", "n": 42})\n'
      'sandbox_await(handle=h)',
    );

    expect(result, {'greeting': 'hello', 'n': 42});
    bridge.dispose();
  });

  // ---------------------------------------------------------------------------
  // Test 2: Bidirectional — parent sends task, child processes and replies
  // ---------------------------------------------------------------------------

  test('child processes task and sends structured reply', () async {
    final bridge = await createBridgeWithMessageBus();

    // Child receives a nested task structure, processes the items list,
    // and replies with a rich result — demonstrating first-class Dart
    // objects (maps, lists, ints, strings, bools) flowing both directions,
    // unlike print() which only returns flat strings.
    // useFutures: false on child bridges (#212) — direct calls, no await.
    final childCode = [
      r'task = msg_recv(name=\"work\")',
      r'items = task[\"items\"]',
      'total = items[0] + items[1] + items[2]',
      r'msg_send(name=\"result\", message={\"total\": total, \"count\": len(items), \"source\": task[\"meta\"][\"origin\"], \"passed\": total > 10})',
    ].join(r'\n');

    final result = await run(
      bridge,
      'h = ${spawn(childCode)}\n'
      'msg_send(name="work", message={"items": [3, 4, 5], '
      '"meta": {"origin": "parent", "priority": 1}})\n'
      'sandbox_await(handle=h)\n'
      'msg_recv(name="result")',
    );

    // Parent receives a typed Dart Map — not a string to parse.
    final reply = result! as Map<String, Object?>;
    expect(reply['total'], 12);
    expect(reply['count'], 3);
    expect(reply['source'], 'parent');
    expect(reply['passed'], true);
    bridge.dispose();
  });

  // ---------------------------------------------------------------------------
  // Test 3: Fan-out/gather — 2 workers with independent channels
  // ---------------------------------------------------------------------------

  test('fan-out to 2 workers and gather results', () async {
    final bridge = await createBridgeWithMessageBus();

    // Each worker receives a value on its input channel, doubles it, and
    // sends the result on its output channel.
    // useFutures: false on child bridges (#212) — direct calls, no await.
    String workerCode(String inCh, String outCh) {
      final recvLine = 'task = msg_recv(name=\\"$inCh\\")';
      const doubleLine = r'doubled = task[\"value\"] * 2';
      final sendLine =
          'msg_send(name=\\"$outCh\\", message={\\"doubled\\": doubled})';
      return [recvLine, doubleLine, sendLine].join(r'\n');
    }

    final result = await run(
      bridge,
      'h1 = ${spawn(workerCode('w1_in', 'w1_out'))}\n'
      'h2 = ${spawn(workerCode('w2_in', 'w2_out'))}\n'
      'msg_send(name="w1_in", message={"value": 10})\n'
      'msg_send(name="w2_in", message={"value": 20})\n'
      'sandbox_await(handle=h1)\n'
      'sandbox_await(handle=h2)\n'
      'r1 = msg_recv(name="w1_out")\n'
      'r2 = msg_recv(name="w2_out")\n'
      '[r1["doubled"], r2["doubled"]]',
    );

    final results = result! as List;
    expect(results[0], 20); // 10 * 2
    expect(results[1], 40); // 20 * 2
    bridge.dispose();
  });
}
