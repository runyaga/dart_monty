import 'dart:async';

import 'package:dart_monty_bridge/dart_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:struct_log/struct_log.dart';

/// Exception thrown when a child isolate fails, is cancelled, or is disposed.
///
/// Preserves the [childId] and, when the failure originated from a Python
/// exception, the full [exception] with structured fields (filename,
/// lineNumber, excType, traceback).
class ChildIsolateException implements Exception {
  /// Creates a [ChildIsolateException].
  const ChildIsolateException({
    required this.childId,
    required this.message,
    this.exception,
  });

  /// The child handle that failed.
  final int childId;

  /// Human-readable error message.
  final String message;

  /// The original [MontyException] when the error originated from Python.
  ///
  /// Null for cancellation, disposal, and non-Python errors.
  final MontyException? exception;

  @override
  String toString() => 'ChildIsolateException(child $childId): $message';
}

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
  /// When null, children automatically inherit plugins from [parentPlugins]
  /// that return non-null from [MontyPlugin.createChildInstance].
  /// [parentPlugins] the parent registry's plugin list — used for automatic
  /// child inheritance when [childPluginRegistryFactory] is null.
  /// [maxChildren] limits concurrent children (default: 16).
  /// [maxDepth] limits recursion depth if children also have IsolatePlugin
  /// (default: 3). Set [currentDepth] when creating nested plugins.
  /// [childLimits] sets resource limits for child interpreters.
  IsolatePlugin({
    required this.platformFactory,
    this.childPluginRegistryFactory,
    this.parentPlugins = const [],
    this.maxChildren = 16,
    this.maxDepth = 3,
    this.currentDepth = 0,
    this.childLimits,
    Logger? logger,
  }) : log = logger ?? LogManager.instance.getLogger('IsolatePlugin');

  /// Creates a fresh [MontyPlatform] for each child.
  final MontyPlatformFactory platformFactory;

  /// Optional factory for child plugin registries.
  ///
  /// When null, children inherit plugins from [parentPlugins] via
  /// [MontyPlugin.createChildInstance].
  final ChildPluginRegistryFactory? childPluginRegistryFactory;

  /// Parent registry's plugins, used for automatic child inheritance.
  ///
  /// Only consulted when [childPluginRegistryFactory] is null.
  final List<MontyPlugin> parentPlugins;

  /// Maximum number of concurrent children.
  final int maxChildren;

  /// Maximum recursion depth for nested isolate plugins.
  final int maxDepth;

  /// Current recursion depth.
  final int currentDepth;

  /// Resource limits applied to child interpreters.
  final MontyLimits? childLimits;

  /// Logger for this plugin instance.
  final Logger log;

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
      log.warning(
        'Spawn rejected: depth limit',
        attributes: {'currentDepth': currentDepth, 'maxDepth': maxDepth},
      );
      throw StateError('Maximum isolate recursion depth ($maxDepth) exceeded.');
    }
    final aliveCount = _children.values.where((c) => c.isAlive).length;
    if (aliveCount >= maxChildren) {
      log.warning(
        'Spawn rejected: concurrency limit',
        attributes: {'alive': aliveCount, 'maxChildren': maxChildren},
      );
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

    // Create child platform, bridge, and wire plugins.
    // All phases are inside a single cleanup scope so that any failure
    // disposes resources created in earlier phases.
    MontyPlatform? platform;
    DefaultMontyBridge? bridge;
    final registryFactory = childPluginRegistryFactory;
    PluginRegistry? childRegistry;
    try {
      try {
        platform = await platformFactory();
      } on Object catch (e, st) {
        log.error(
          'Child platform creation failed',
          error: e,
          stackTrace: st,
          attributes: {'phase': 'platform'},
        );
        rethrow;
      }
      bridge = DefaultMontyBridge(platform: platform, limits: limits);
      log.debug(
        'Child bridge created',
        attributes: {
          'codeLength': code.length,
          if (limits != null) 'limits': limits.toString(),
        },
      );

      // Wire plugins onto child bridge.
      // Each phase is wrapped separately so we can log which stage failed.
      if (registryFactory != null) {
        // Explicit factory takes precedence.
        try {
          childRegistry = await registryFactory();
        } on Object catch (e, st) {
          log.error(
            'Child plugin factory failed',
            error: e,
            stackTrace: st,
            attributes: {'phase': 'factory'},
          );
          rethrow;
        }
      } else if (parentPlugins.isNotEmpty) {
        // Auto-inherit from parent plugins via createChildInstance().
        try {
          childRegistry = _buildInheritedRegistry();
        } on Object catch (e, st) {
          log.error(
            'Child plugin inheritance failed',
            error: e,
            stackTrace: st,
            attributes: {'phase': 'inheritance'},
          );
          rethrow;
        }
      }
      if (childRegistry != null) {
        // Capture plugin count before attachTo in case the registry is in a
        // broken state after the error.
        final pluginCount = childRegistry.plugins.length;
        try {
          await childRegistry.attachTo(bridge);
          log.debug(
            'Child plugins attached',
            attributes: {'pluginCount': childRegistry.plugins.length},
          );
        } on Object catch (e, st) {
          log.error(
            'Child plugin attachment failed',
            error: e,
            stackTrace: st,
            attributes: {
              'phase': 'attachTo',
              'pluginCount': pluginCount,
            },
          );
          rethrow;
        }
      }
    } on Object {
      if (bridge != null) bridge.dispose();
      if (platform != null) await platform.dispose();
      if (childRegistry != null) await childRegistry.disposeAll();
      rethrow;
    }

    final id = _nextId++;
    final completer = Completer<Object?>();
    completer.future.ignore();

    log.info(
      'Child spawned',
      attributes: {'childId': id, 'depth': currentDepth},
    );

    // Execute child and listen for completion.
    final stream = bridge.execute(code);
    String? errorMessage;
    MontyException? errorException;
    Object? childValue;
    String? childPrintOutput;

    final subscription = stream.listen(
      (event) {
        if (event is BridgeRunError) {
          errorMessage = event.message;
          errorException = event.exception;
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
        // bridge and platform are guaranteed non-null here — the try block
        // succeeded before the stream listener was created.
        try {
          bridge!.dispose();
          await platform!.dispose();
          if (childRegistry != null) await childRegistry.disposeAll();
        } on Object catch (e, st) {
          log.warning(
            'Child cleanup error (swallowed)',
            error: e,
            stackTrace: st,
            attributes: {'childId': id},
          );
        }

        if (!completer.isCompleted) {
          if (errorMessage != null) {
            final truncated = errorMessage!.length > 200
                ? '${errorMessage!.substring(0, 200)}…'
                : errorMessage!;
            log.debug(
              'Child failed',
              attributes: {'childId': id, 'error': truncated},
            );
            completer.completeError(
              ChildIsolateException(
                childId: id,
                message: errorMessage!,
                exception: errorException,
              ),
            );
          } else {
            log.debug('Child completed', attributes: {'childId': id});
            completer.complete(childValue);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        final child = _children[id];
        if (child != null) child.isAlive = false;
        log.error(
          'Child stream error',
          error: error,
          attributes: {'childId': id},
        );
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
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

  /// Builds a child registry from parent plugins that opt into inheritance.
  PluginRegistry? _buildInheritedRegistry() {
    final childPlugins = <MontyPlugin>[];
    for (final plugin in parentPlugins) {
      // Skip IsolatePlugin itself — children get their own via depth control.
      if (plugin is IsolatePlugin) continue;
      final child = plugin.createChildInstance();
      if (child == null) continue;
      // Guard: returning `this` would cause the parent plugin to be disposed
      // when the child finishes, and returning an IsolatePlugin would bypass
      // depth limiting.
      assert(
        !identical(child, plugin),
        'createChildInstance() must return a new instance, not `this`.',
      );
      if (child is IsolatePlugin) {
        throw StateError(
          'createChildInstance() must not return an IsolatePlugin.',
        );
      }
      childPlugins.add(child);
    }
    if (childPlugins.isEmpty) return null;
    final registry = PluginRegistry();
    childPlugins.forEach(registry.register);
    return registry;
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

    log.info('Cancelling child', attributes: {'childId': handle});
    try {
      await child.cancel();
    } finally {
      if (!child.completer.isCompleted) {
        child.completer.completeError(
          ChildIsolateException(childId: handle, message: 'cancelled'),
        );
      }
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
    log.debug('Child freed', attributes: {'childId': handle});
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

    final aliveCount = _children.values.where((c) => c.isAlive).length;
    log.info(
      'Disposing IsolatePlugin',
      attributes: {
        'totalChildren': _children.length,
        'aliveChildren': aliveCount,
      },
    );

    // Cancel all living children.
    for (final entry in _children.entries) {
      final child = entry.value;
      if (!child.isAlive) continue;

      try {
        await child.cancel();
      } on Object catch (e, st) {
        // Best-effort logging — don't let a sink failure break the loop.
        try {
          log.warning(
            'Error cancelling child during dispose',
            error: e,
            stackTrace: st,
            attributes: {'childId': entry.key},
          );
        } on Object {
          // Sink failure — nothing we can do.
        }
      }
      if (!child.completer.isCompleted) {
        child.completer.completeError(
          ChildIsolateException(
            childId: entry.key,
            message: 'disposed with parent',
          ),
        );
      }
    }
    _children.clear();
  }
}
