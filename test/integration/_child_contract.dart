import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../acceptance/_platform.dart';

/// Real sessions on the same transports as the D3 witnesses.
Future<Monty> childContractPool() async {
  final pool = await Monty.start(
    workerLocation: acceptanceWorkerLocation,
    maxProcesses: 3,
    checkoutTimeout: const Duration(seconds: 5),
  );
  addTearDown(pool.close);

  return pool;
}

/// The caller owns these sessions: coordinator tests do not exercise sandbox
/// checkout, origin tracking, or terminal session cleanup.
Future<MontyBridge> childContractBridge(Monty pool) async {
  final session = await pool.checkout();
  addTearDown(session.close);
  final bridge = MontyBridge(session: session);
  addTearDown(bridge.dispose);

  return bridge;
}

/// Test-local clone/exclude extension, with observable owned instances.
final class ChildContractExtension extends MontyExtension {
  /// Creates a parent or child instance.
  ChildContractExtension(
    this.namespace, {
    this.childPolicy = ChildPolicy.clone,
    this.context,
    this.throwOnDispose = false,
  });

  @override
  final String namespace;

  @override
  final ChildPolicy childPolicy;

  /// Context received by the clone factory.
  final ChildSpawnContext? context;

  /// Whether disposal deliberately fails after counting the attempt.
  final bool throwOnDispose;

  /// Instances owned by child coordinators.
  final List<ChildContractExtension> clones = [];

  /// Disposal attempts, including accidental repeated disposal.
  int disposals = 0;

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: HostFunctionSchema(name: '${namespace}_id'),
      handler: (_, _) async => MontyInt(context?.childId ?? -1),
    ),
  ];

  @override
  MontyExtension createChildInstance(ChildSpawnContext context) {
    final clone = ChildContractExtension(
      namespace,
      context: context,
      throwOnDispose: throwOnDispose,
    );
    clones.add(clone);

    return clone;
  }

  @override
  Future<void> onDispose() async {
    disposals++;
    await super.onDispose();
    if (throwOnDispose) throw StateError('dispose $namespace');
  }
}

/// Invokes one of the seven sandbox functions through the runtime.
Future<MontyValue> spawnChild(MontyRuntime runtime, String code) =>
    runtime.invoke('sandbox_spawn', {'code': MontyString(code)});

/// Waits for a retained handle.
Future<MontyValue> awaitChild(MontyRuntime runtime, MontyValue handle) =>
    runtime.invoke('sandbox_await', {'handle': handle});

/// Releases a retained or running handle.
Future<MontyValue> freeChild(MontyRuntime runtime, MontyValue handle) =>
    runtime.invoke('sandbox_free', {'handle': handle});
