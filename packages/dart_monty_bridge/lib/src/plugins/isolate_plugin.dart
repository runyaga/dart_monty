import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Factory that creates a fresh [MontyPlatform] for each child isolate.
typedef MontyPlatformFactory = Future<MontyPlatform> Function();

/// Factory that creates and configures a [PluginRegistry] for child bridges.
///
/// Return `null` to give children only introspection builtins (no plugins).
typedef ChildPluginRegistryFactory = Future<PluginRegistry?> Function();

/// Tracks a spawned child interpreter.
class _ChildHandle {
  _ChildHandle({
    required this.bridge,
    required this.platform,
    required this.completer,
    required this.subscription,
    this.registry,
  });

  final DefaultMontyBridge bridge;
  final MontyPlatform platform;
  final Completer<Object?> completer;
  final StreamSubscription<BridgeEvent> subscription;
  final PluginRegistry? registry;
  bool isAlive = true;

  /// Captured print output from the child (set on completion).
  String? printOutput;

  Future<void> cancel() async {
    isAlive = false;
    await subscription.cancel();
    bridge.dispose();
    await platform.dispose();
    if (registry != null) await registry!.disposeAll();
  }
}

/// Plugin that spawns Python scripts in separate Monty interpreter instances.
///
/// Each child gets its own [MontyPlatform] (via [platformFactory]) and
/// [DefaultMontyBridge]. The parent Python script can spawn children with
/// `isolate_spawn(code)` and await their results with `isolate_await(handle)`.
///
/// Children are isolated: each has its own interpreter state.
/// All living children are killed when this plugin is disposed.
class IsolatePlugin extends MontyPlugin {
  /// Creates an [IsolatePlugin].
  ///
  /// [platformFactory] creates a fresh [MontyPlatform] for each child.
  /// [childPluginRegistryFactory] optionally provides plugins to children.
  /// [maxChildren] limits concurrent children (default: 16).
  /// [maxDepth] limits recursion depth if children also have IsolatePlugin
  /// (default: 3). Set [currentDepth] when creating nested plugins.
  /// [childLimits] sets resource limits for child interpreters.
  IsolatePlugin({
    required this.platformFactory,
    this.childPluginRegistryFactory,
    this.maxChildren = 16,
    this.maxDepth = 3,
    this.currentDepth = 0,
    this.childLimits,
  });

  /// Creates a fresh [MontyPlatform] for each child.
  final MontyPlatformFactory platformFactory;

  /// Optional factory for child plugin registries.
  final ChildPluginRegistryFactory? childPluginRegistryFactory;

  /// Maximum number of concurrent children.
  final int maxChildren;

  /// Maximum recursion depth for nested isolate plugins.
  final int maxDepth;

  /// Current recursion depth.
  final int currentDepth;

  /// Resource limits applied to child interpreters.
  final MontyLimits? childLimits;

  final Map<int, _ChildHandle> _children = {};
  int _nextId = 0;
  bool _disposed = false;

  @override
  String get namespace => 'isolate';

  @override
  String? get systemPromptContext =>
      'Spawn Python scripts in isolated interpreter instances. '
      'Each child has its own state. Use for parallel computation.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_spawn',
        description:
            'Spawn a Python script in a new isolated interpreter. '
            'Returns an integer handle.',
        params: [
          HostParam(
            name: 'code',
            type: HostParamType.string,
            description: 'Python code to execute.',
          ),
          HostParam(
            name: 'timeout_ms',
            type: HostParamType.integer,
            isRequired: false,
            description: 'Execution timeout in milliseconds.',
          ),
          HostParam(
            name: 'memory_bytes',
            type: HostParamType.integer,
            isRequired: false,
            description: 'Memory limit in bytes.',
          ),
        ],
      ),
      handler: _handleSpawn,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_await',
        description:
            'Wait for a spawned child to complete and return '
            'its result. Raises an error if the child failed.',
        params: [
          HostParam(
            name: 'handle',
            type: HostParamType.integer,
            description: 'Handle returned by isolate_spawn.',
          ),
        ],
      ),
      handler: _handleAwait,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_await_all',
        description:
            'Wait for multiple children to complete. '
            'Returns a list of results in handle order.',
        params: [
          HostParam(
            name: 'handles',
            type: HostParamType.list,
            description: 'List of handles from isolate_spawn.',
          ),
        ],
      ),
      handler: _handleAwaitAll,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_is_alive',
        description: 'Check whether a child is still running.',
        params: [
          HostParam(
            name: 'handle',
            type: HostParamType.integer,
            description: 'Handle returned by isolate_spawn.',
          ),
        ],
      ),
      handler: _handleIsAlive,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_cancel',
        description: 'Cancel a running child. No-op if already finished.',
        params: [
          HostParam(
            name: 'handle',
            type: HostParamType.integer,
            description: 'Handle returned by isolate_spawn.',
          ),
        ],
      ),
      handler: _handleCancel,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_free',
        description:
            'Release a completed child handle and free its resources. '
            'Raises an error if the child is still running.',
        params: [
          HostParam(
            name: 'handle',
            type: HostParamType.integer,
            description: 'Handle returned by isolate_spawn.',
          ),
        ],
      ),
      handler: _handleFree,
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'isolate_get_output',
        description:
            'Get captured Python print() output from a completed child. '
            'Raises an error if the child is still running. '
            'Returns a string of all print() output, or null if the child '
            'produced no print() output.',
        params: [
          HostParam(
            name: 'handle',
            type: HostParamType.integer,
            description: 'Handle returned by isolate_spawn.',
          ),
        ],
      ),
      handler: _handleGetOutput,
    ),
  ];

  Future<Object?> _handleSpawn(Map<String, Object?> args) async {
    if (_disposed) throw StateError('IsolatePlugin is disposed.');
    if (currentDepth >= maxDepth) {
      throw StateError('Maximum isolate recursion depth ($maxDepth) exceeded.');
    }
    if (_children.values.where((c) => c.isAlive).length >= maxChildren) {
      throw StateError('Maximum concurrent children ($maxChildren) reached.');
    }

    final code = args['code']! as String;
    final timeoutMs = args['timeout_ms'] as int?;
    final memoryBytes = args['memory_bytes'] as int?;

    // Build per-child resource limits.
    var limits = childLimits;
    if (timeoutMs != null || memoryBytes != null) {
      limits = MontyLimits(
        timeoutMs: timeoutMs ?? childLimits?.timeoutMs,
        memoryBytes: memoryBytes ?? childLimits?.memoryBytes,
        stackDepth: childLimits?.stackDepth,
      );
    }

    // Create child platform and bridge.
    final platform = await platformFactory();
    final bridge = DefaultMontyBridge(platform: platform, limits: limits);

    // Wire plugins onto child bridge if factory provided.
    final registryFactory = childPluginRegistryFactory;
    PluginRegistry? childRegistry;
    if (registryFactory != null) {
      childRegistry = await registryFactory();
      if (childRegistry != null) {
        await childRegistry.attachTo(bridge);
      }
    }

    final id = _nextId++;
    final completer = Completer<Object?>();
    completer.future.ignore();

    // Execute child and listen for completion.
    final stream = bridge.execute(code);
    String? errorMessage;
    Object? childValue;
    String? childPrintOutput;

    final subscription = stream.listen(
      (event) {
        if (event is BridgeRunError) {
          errorMessage = event.message;
          childPrintOutput ??= event.printOutput;
        } else if (event is BridgeRunFinished) {
          childValue = event.value;
          childPrintOutput = event.printOutput;
        }
      },
      onDone: () async {
        final child = _children[id];
        if (child == null) return;
        child
          ..isAlive = false
          ..printOutput = childPrintOutput;

        // Clean up child resources.
        try {
          bridge.dispose();
          await platform.dispose();
          if (childRegistry != null) await childRegistry.disposeAll();
        } on Object {
          // Best-effort cleanup — don't let disposal errors mask the
          // child result.
        }

        if (!completer.isCompleted) {
          if (errorMessage != null) {
            completer.completeError(
              Exception('Child $id failed: $errorMessage'),
            );
          } else {
            completer.complete(childValue);
          }
        }
      },
      onError: (Object error) {
        final child = _children[id];
        if (child != null) child.isAlive = false;
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    _children[id] = _ChildHandle(
      bridge: bridge,
      platform: platform,
      completer: completer,
      subscription: subscription,
      registry: childRegistry,
    );

    return id;
  }

  Future<Object?> _handleAwait(Map<String, Object?> args) async {
    final handle = args['handle']! as int;
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    return child.completer.future;
  }

  Future<Object?> _handleAwaitAll(Map<String, Object?> args) async {
    final raw = args['handles']! as List<Object?>;
    final handles = raw.cast<num>().map((n) => n.toInt()).toList();

    final futures = <Future<Object?>>[];
    for (final handle in handles) {
      final child = _children[handle];
      if (child == null) {
        throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
      }
      futures.add(child.completer.future);
    }

    return Future.wait(futures);
  }

  Future<Object?> _handleIsAlive(Map<String, Object?> args) async {
    final handle = args['handle']! as int;
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    return child.isAlive;
  }

  Future<Object?> _handleCancel(Map<String, Object?> args) async {
    final handle = args['handle']! as int;
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    if (!child.isAlive) return null;

    await child.cancel();
    if (!child.completer.isCompleted) {
      child.completer.completeError(
        Exception('Child $handle was cancelled.'),
      );
    }

    return null;
  }

  Future<Object?> _handleFree(Map<String, Object?> args) async {
    final handle = args['handle']! as int;
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    if (child.isAlive) {
      throw StateError(
        'Child $handle is still running. Await it before freeing.',
      );
    }
    _children.remove(handle);
    return null;
  }

  Future<Object?> _handleGetOutput(Map<String, Object?> args) async {
    final handle = args['handle']! as int;
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    if (child.isAlive) {
      throw StateError(
        'Child $handle is still running. Await it before reading output.',
      );
    }
    return child.printOutput;
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    if (_disposed) return;
    _disposed = true;

    // Cancel all living children.
    for (final entry in _children.entries) {
      final child = entry.value;
      if (!child.isAlive) continue;

      await child.cancel();
      if (!child.completer.isCompleted) {
        child.completer.completeError(
          Exception('Child ${entry.key} disposed with parent.'),
        );
      }
    }
    _children.clear();
  }
}
