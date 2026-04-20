import 'dart:async';

import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/default_monty_bridge.dart';
import 'package:dart_monty/src/host_args.dart';
import 'package:dart_monty/src/host_context.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/host_param.dart';
import 'package:dart_monty/src/host_param_type.dart';
import 'package:dart_monty/src/monty_backend_kind.dart';
import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/monty_runtime_ref.dart';
import 'package:dart_monty/src/param_render_hint.dart';
import 'package:dart_monty/src/plugin_registry.dart';
import 'package:dart_monty/src/stateful_plugin.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;
import 'package:signals_core/signals_core.dart';

/// Exception thrown when a child sandbox fails or is disposed.
///
/// Preserves the [childId] and, when the failure originated from a Python
/// exception, the full [exception] with structured fields (filename,
/// lineNumber, excType, traceback).
class ChildSandboxException implements Exception {
  /// Creates a [ChildSandboxException].
  const ChildSandboxException({
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
  /// Null for disposal and non-Python errors.
  final MontyException? exception;

  @override
  String toString() => 'ChildSandboxException(child $childId): $message';
}

// ---------------------------------------------------------------------------
// ChildState — sealed lifecycle state for spawned children.
// ---------------------------------------------------------------------------

/// The lifecycle state of a spawned child sandbox.
///
/// Subscribe to [SandboxPlugin.childrenSignal] for reactive observation:
/// ```dart
/// effect(() {
///   for (final entry in plugin.childrenSignal.value.entries) {
///     switch (entry.value) {
///       case ChildRunning(): // still executing
///       case ChildCompleted(:final value): // finished with value
///       case ChildFailed(:final message): // finished with error
///       case ChildDisposed(): // cancelled or parent disposed
///     }
///   }
/// });
/// ```
sealed class ChildState {
  /// Creates a [ChildState].
  const ChildState();
}

/// The child is still executing.
final class ChildRunning extends ChildState {
  /// Creates a [ChildRunning].
  const ChildRunning();
}

/// The child finished successfully.
final class ChildCompleted extends ChildState {
  /// Creates a [ChildCompleted].
  const ChildCompleted({required this.value, this.printOutput});

  /// The Python return value (JSON-decoded), or `null`.
  final Object? value;

  /// Captured `print()` output, or `null` if the child produced none.
  final String? printOutput;
}

/// The child finished with an error.
final class ChildFailed extends ChildState {
  /// Creates a [ChildFailed].
  const ChildFailed({
    required this.message,
    this.exception,
    this.printOutput,
  });

  /// Human-readable error description.
  final String message;

  /// The original [MontyException] when the error came from Python.
  ///
  /// Null for non-Python failures.
  final MontyException? exception;

  /// Captured `print()` output, or `null` if the child produced none.
  final String? printOutput;
}

/// The child was cancelled or the parent plugin was disposed before completion.
final class ChildDisposed extends ChildState {
  /// Creates a [ChildDisposed].
  const ChildDisposed();
}

// ---------------------------------------------------------------------------
// Factory typedefs
// ---------------------------------------------------------------------------

/// Factory that creates a fresh [MontyPlatform] for each child sandbox.
typedef MontyPlatformFactory = Future<MontyPlatform> Function();

/// Builds a system prompt fragment from infrastructure context.
///
/// Called during [SandboxPlugin._handleSpawn] to produce static,
/// infrastructure-level prompt content (e.g., child identity, workspace path).
/// Return `null` to skip the builder layer for a given child.
typedef ChildSystemPromptBuilder = String? Function(ChildSpawnContext context);

/// Tracks a spawned child interpreter.
class _ChildHandle {
  _ChildHandle({
    required this.bridge,
    required this.platform,
    required this.completer,
    required this.subscription,
    required this.registry,
  });

  final DefaultMontyBridge bridge;
  final MontyPlatform platform;
  final Completer<Object?> completer;
  final StreamSubscription<BridgeEvent> subscription;
  final PluginRegistry registry;

  /// Reactive lifecycle state — starts as [ChildRunning].
  final Signal<ChildState> state = signal(const ChildRunning());

  /// Whether the child is still executing.
  bool get isAlive => state.value is ChildRunning;

  /// Captured `print()` output from a completed child, or `null`.
  String? get printOutput => switch (state.value) {
    ChildCompleted(printOutput: final output) ||
    ChildFailed(printOutput: final output) => output,
    _ => null,
  };

  Future<void> cancel() async {
    state.value = const ChildDisposed();
    // Dispose plugins FIRST — this unblocks pending handler Futures
    // (e.g., MessageBusPlugin completes waiters with StateError).
    // The bridge/stream must still be alive to deliver the resulting errors.
    await registry.disposeAll();
    await subscription.cancel();
    bridge.dispose();
    await platform.dispose();
  }
}

// ---------------------------------------------------------------------------
// Schema constants for SandboxPlugin host functions.
// ---------------------------------------------------------------------------

const _spawnSchema = HostFunctionSchema(
  name: 'sandbox_spawn',
  description:
      'Spawn a Python script in a new sandboxed interpreter. '
      'Returns an integer handle.',
  params: [
    HostParam(
      name: 'code',
      type: HostParamType.string,
      description: 'Python code to execute.',
      renderAs: ParamRenderHint.python,
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
    HostParam(
      name: 'system_prompt',
      type: HostParamType.string,
      isRequired: false,
      description:
          'Custom system prompt fragment for the child. '
          'Appended after the infrastructure builder prompt.',
    ),
  ],
);

const _awaitSchema = HostFunctionSchema(
  name: 'sandbox_await',
  description:
      'Wait for a spawned child to complete and return '
      'its result. Raises an error if the child failed.',
  params: [
    HostParam(
      name: 'handle',
      type: HostParamType.integer,
      description: 'Handle returned by sandbox_spawn.',
    ),
  ],
);

const _awaitAllSchema = HostFunctionSchema(
  name: 'sandbox_await_all',
  description:
      'Wait for multiple children to complete. '
      'Returns a list of results in handle order.',
  params: [
    HostParam(
      name: 'handles',
      type: HostParamType.list,
      description: 'List of handles from sandbox_spawn.',
    ),
  ],
);

const _isAliveSchema = HostFunctionSchema(
  name: 'sandbox_is_alive',
  description: 'Check whether a child is still running.',
  params: [
    HostParam(
      name: 'handle',
      type: HostParamType.integer,
      description: 'Handle returned by sandbox_spawn.',
    ),
  ],
);

const _freeSchema = HostFunctionSchema(
  name: 'sandbox_free',
  description:
      'Release a completed child handle and free its resources. '
      'Raises an error if the child is still running.',
  params: [
    HostParam(
      name: 'handle',
      type: HostParamType.integer,
      description: 'Handle returned by sandbox_spawn.',
    ),
  ],
);

const _getOutputSchema = HostFunctionSchema(
  name: 'sandbox_get_output',
  description:
      'Get captured Python print() output from a completed child. '
      'Raises an error if the child is still running. '
      'Returns a string of all print() output, or null if the child '
      'produced no print() output.',
  params: [
    HostParam(
      name: 'handle',
      type: HostParamType.integer,
      description: 'Handle returned by sandbox_spawn.',
    ),
  ],
);

const _gatherSchema = HostFunctionSchema(
  name: 'sandbox_gather',
  description:
      'Wait for multiple children and return attributed results. '
      'Each element is a dict with handle, value, and output keys.',
  params: [
    HostParam(
      name: 'handles',
      type: HostParamType.list,
      description: 'List of handles from sandbox_spawn.',
    ),
  ],
);

/// Plugin that spawns Python scripts in separate Monty interpreter instances.
///
/// Each child gets its own [MontyPlatform] (via [platformFactory]) and
/// [DefaultMontyBridge]. The parent Python script can spawn children with
/// `sandbox_spawn(code)` and await their results with `sandbox_await(handle)`.
///
/// Children are sandboxed: each has its own interpreter state.
/// All living children are killed when this plugin is disposed.
///
/// ## Child plugin and VFS inheritance
///
/// Child plugins and OS handlers are inherited from the parent
/// [PluginRegistry] via [PluginRegistry.spawnChild]. Plugins opt into
/// inheritance by overriding [MontyPlugin.createChildInstance]; the child's
/// filesystem visibility is controlled by [childVfsStrategy].
///
/// `SandboxPlugin` MUST be attached through a [PluginRegistry] — it uses the
/// parent registry to compose the child.
class SandboxPlugin extends MontyPlugin
    with StatefulPlugin<Map<int, ChildState>> {
  /// Creates a [SandboxPlugin].
  ///
  /// [platformFactory] creates a fresh [MontyPlatform] for each child.
  /// [childVfsStrategy] selects how the child's `Path.` handler relates to
  /// the parent's — defaults to [ChildVfsStrategy.isolated].
  /// [maxChildren] limits concurrent children (default: 16).
  /// [maxDepth] limits recursion depth if children also have SandboxPlugin
  /// (default: 3). Set [currentDepth] when creating nested plugins.
  /// [childLimits] sets resource limits for child interpreters.
  SandboxPlugin({
    required this.platformFactory,
    this.childVfsStrategy = ChildVfsStrategy.isolated,
    this.maxChildren = 16,
    this.maxDepth = 3,
    this.currentDepth = 0,
    this.childLimits,
    this.sandboxBaseDir,
    this.systemPromptBuilder,
  }) {
    setInitialState(const {});
  }

  /// Creates a fresh [MontyPlatform] for each child.
  final MontyPlatformFactory platformFactory;

  /// How the child's `Path.` handler is derived from the parent's.
  final ChildVfsStrategy childVfsStrategy;

  /// Maximum number of concurrent children.
  final int maxChildren;

  /// Maximum recursion depth for nested sandbox plugins.
  final int maxDepth;

  /// Current recursion depth.
  final int currentDepth;

  /// Resource limits applied to child interpreters.
  final MontyLimits? childLimits;

  /// Base directory for per-child sandbox working directories.
  ///
  /// When non-null, each child receives a [ChildSpawnContext] with
  /// `workingDirectory` set to `$sandboxBaseDir/.sandboxes/child_$id`.
  /// The directory is **not** created by this plugin — consumers (e.g.,
  /// `FsPlugin.createChildInstance`) are responsible for creation.
  final String? sandboxBaseDir;

  /// Optional builder for static, infrastructure-level system prompt content.
  ///
  /// Called once per child spawn with the [ChildSpawnContext]. The returned
  /// string (if non-null) is prepended before any runtime `system_prompt`
  /// argument from `sandbox_spawn`.
  final ChildSystemPromptBuilder? systemPromptBuilder;

  final Map<int, _ChildHandle> _children = {};
  int _nextId = 0;
  bool _disposed = false;

  /// Reactive snapshot of every child's [ChildState], keyed by handle.
  ///
  /// Updated whenever a child transitions state (spawn, complete, fail, free,
  /// or dispose). Subscribe via `effect` for reactive UI or monitoring:
  /// ```dart
  /// effect(() => print(plugin.childrenSignal.value));
  /// ```
  ReadonlySignal<Map<int, ChildState>> get childrenSignal => stateSignal;

  /// Reactive count of children still in [ChildRunning] state.
  ///
  /// Derived from [childrenSignal]; updates automatically.
  ReadonlySignal<int> get aliveCountSignal => _aliveCountSignal;

  late final Computed<int> _aliveCountSignal = computed(
    () => state.values.whereType<ChildRunning>().length,
  );

  @override
  String get namespace => 'sandbox';

  /// FFI-only. Spawning a second interpreter crashes the parent WASM
  /// session; see `project_sandbox_wasm_finding` in the backlog memory.
  @override
  Set<MontyBackendKind> get supportedBackends => const {MontyBackendKind.ffi};

  @override
  String? get systemPromptContext =>
      'Spawn Python scripts in sandboxed interpreter instances. '
      'Each child has its own state. Use for parallel computation. '
      'Use sandbox_gather for attributed results with handle and output.';

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _spawnSchema, handler: _handleSpawn),
    HostFunction(schema: _awaitSchema, handler: _handleAwait),
    HostFunction(schema: _awaitAllSchema, handler: _handleAwaitAll),
    HostFunction(schema: _isAliveSchema, handler: _handleIsAlive),
    HostFunction(schema: _freeSchema, handler: _handleFree),
    HostFunction(schema: _getOutputSchema, handler: _handleGetOutput),
    HostFunction(schema: _gatherSchema, handler: _handleGather),
  ];

  @override
  Future<void> onDispose() async {
    if (_disposed) return;
    _disposed = true;

    final aliveCount = _children.values.where((c) => c.isAlive).length;
    logger.info(
      'Disposing SandboxPlugin',
      attributes: {
        'totalChildren': _children.length,
        'aliveChildren': aliveCount,
      },
    );

    // Tear down all living children.
    for (final entry in _children.entries) {
      final child = entry.value;
      if (!child.isAlive) continue;

      try {
        await child.cancel();
      } on Object catch (e, st) {
        // Best-effort logging -- don't let a sink failure break the loop.
        try {
          logger.warning(
            'Error tearing down child during dispose',
            error: e,
            stackTrace: st,
            attributes: {'childId': entry.key},
          );
        } on Object {
          // Sink failure -- nothing we can do.
        }
      }
      if (!child.completer.isCompleted) {
        child.completer.completeError(
          ChildSandboxException(
            childId: entry.key,
            message: 'disposed with parent',
          ),
          StackTrace.current,
        );
      }
    }
    _children.clear();
    state = const <int, ChildState>{};
    await super.onDispose();
  }

  Future<Object?> _handleSpawn(Map<String, Object?> args, HostContext ctx) async {
    _validateSpawnRequest();

    final code = args.str('code');
    final runtimePrompt = args.strOrNull('system_prompt');
    final limits = _buildChildLimits(args);

    final id = _nextId++;
    final spawnContext = ChildSpawnContext(
      childId: id,
      workingDirectory: sandboxBaseDir != null
          ? p.join(sandboxBaseDir!, '.sandboxes', 'child_$id')
          : null,
    );

    final (
      platform,
      bridge,
      childRegistry,
    ) = await _createChildPlatformAndBridge(
      spawnContext,
      limits,
      runtimePrompt,
      code.length,
    );

    // Post-await disposed check — the plugin may have been disposed while
    // _createChildPlatformAndBridge was in flight.
    if (_disposed) {
      bridge.dispose();
      await platform.dispose();
      await childRegistry.disposeAll();
      throw StateError('SandboxPlugin was disposed during child spawn.');
    }

    final completer = Completer<Object?>();
    completer.future.ignore();
    logger.info(
      'Child spawned',
      attributes: {'childId': id, 'depth': currentDepth},
    );

    final stream = bridge.execute(code);
    final subscription = _setupChildListener(
      bridge: bridge,
      platform: platform,
      registry: childRegistry,
      completer: completer,
      childId: id,
      stream: stream,
      parent: ctx.runtime,
    );

    _children[id] = _ChildHandle(
      bridge: bridge,
      platform: platform,
      completer: completer,
      subscription: subscription,
      registry: childRegistry,
    );
    _updateChildrenSignal();

    return id;
  }

  /// Throws if the plugin is disposed or resource limits are exceeded.
  void _validateSpawnRequest() {
    if (_disposed) throw StateError('SandboxPlugin is disposed.');
    if (currentDepth >= maxDepth) {
      logger.warning(
        'Spawn rejected: depth limit',
        attributes: {'currentDepth': currentDepth, 'maxDepth': maxDepth},
      );
      throw StateError('Maximum sandbox recursion depth ($maxDepth) exceeded.');
    }
    final aliveCount = _children.values.where((c) => c.isAlive).length;
    if (aliveCount >= maxChildren) {
      logger.warning(
        'Spawn rejected: concurrency limit',
        attributes: {'alive': aliveCount, 'maxChildren': maxChildren},
      );
      throw StateError('Maximum concurrent children ($maxChildren) reached.');
    }
  }

  /// Parses optional timeout/memory overrides from [args] and merges with
  /// [childLimits].
  MontyLimits? _buildChildLimits(Map<String, Object?> args) {
    final timeoutMs = args.intArgOrNull('timeout_ms');
    final memoryBytes = args.intArgOrNull('memory_bytes');
    if (timeoutMs == null && memoryBytes == null) return childLimits;

    return MontyLimits(
      timeoutMs: timeoutMs ?? childLimits?.timeoutMs,
      memoryBytes: memoryBytes ?? childLimits?.memoryBytes,
      stackDepth: childLimits?.stackDepth,
    );
  }

  /// Creates the child platform, bridge, wires plugins, and attaches the
  /// registry.
  ///
  /// Disposes all partially-created resources on failure.
  Future<(MontyPlatform, DefaultMontyBridge, PluginRegistry)>
  _createChildPlatformAndBridge(
    ChildSpawnContext spawnContext,
    MontyLimits? limits,
    String? runtimePrompt,
    int codeLength,
  ) async {
    MontyPlatform? platform;
    DefaultMontyBridge? bridge;
    PluginRegistry? childRegistry;
    try {
      try {
        platform = await platformFactory();
      } on Object catch (e, st) {
        logger.error(
          'Child platform creation failed',
          error: e,
          stackTrace: st,
          attributes: {'phase': 'platform'},
        );
        rethrow;
      }
      bridge = DefaultMontyBridge(
        platform: platform,
        limits: limits,
        useFutures: false,
        logger: logger.child('child.${spawnContext.childId}'),
      );
      logger.debug(
        'Child bridge created',
        attributes: {
          'codeLength': codeLength,
          if (limits != null) 'limits': limits.toString(),
        },
      );

      childRegistry = await _wireChildPlugins(
        spawnContext,
        bridge,
        runtimePrompt,
      );
    } on Object {
      if (bridge != null) bridge.dispose();
      if (platform != null) await platform.dispose();
      if (childRegistry != null) await childRegistry.disposeAll();
      rethrow;
    }

    return (platform, bridge, childRegistry);
  }

  /// Creates and attaches a child [PluginRegistry] by delegating to
  /// [PluginRegistry.spawnChild] on the parent registry. Child plugins are
  /// composed via [MontyPlugin.createChildInstance]; the child OS handler
  /// follows [childVfsStrategy].
  ///
  /// Relies on [MontyPlugin.registry] being injected — i.e., this plugin
  /// must be attached through a [PluginRegistry].
  Future<PluginRegistry> _wireChildPlugins(
    ChildSpawnContext spawnContext,
    DefaultMontyBridge bridge,
    String? runtimePrompt,
  ) async {
    final childPrompt = _buildChildSystemPrompt(spawnContext, runtimePrompt);
    try {
      final childRegistry = await registry.spawnChild(
        context: spawnContext,
        bridge: bridge,
        vfsStrategy: childVfsStrategy,
        childSystemPromptPrefix: childPrompt,
      );
      logger.debug(
        'Child plugins attached',
        attributes: {'pluginCount': childRegistry.plugins.length},
      );

      return childRegistry;
    } on Object catch (e, st) {
      logger.error(
        'Child plugin inheritance failed',
        error: e,
        stackTrace: st,
        attributes: {'phase': 'spawnChild'},
      );
      rethrow;
    }
  }

  /// Subscribes to [stream] and wires completion/error handling for a child.
  ///
  /// When [parent] is non-null, every child event is also re-emitted on the
  /// parent runtime's broadcast `events` stream wrapped in a
  /// [BridgeChildEvent] tagged with the child's integer id — giving
  /// observers a single attributed ordering across the ownership tree.
  StreamSubscription<BridgeEvent> _setupChildListener({
    required DefaultMontyBridge bridge,
    required MontyPlatform platform,
    required PluginRegistry registry,
    required Completer<Object?> completer,
    required int childId,
    required Stream<BridgeEvent> stream,
    required MontyRuntimeRef? parent,
  }) {
    String? errorMessage;
    MontyException? errorException;
    Object? value;
    String? printOutput;
    final childHandle = '$childId';

    return stream.listen(
      (event) {
        parent?.emitChildEvent(childHandle, event);
        if (event is BridgeRunError) {
          errorMessage = event.message;
          errorException = event.exception;
          printOutput ??= event.printOutput;
        } else if (event is BridgeRunFinished) {
          value = event.value;
          printOutput = event.printOutput;
        }
      },
      onDone: () => unawaited(
        _onChildDone(
          childId,
          bridge,
          platform,
          registry,
          completer,
          errorMessage: errorMessage,
          errorException: errorException,
          value: value,
          printOutput: printOutput,
        ),
      ),
      onError: (Object error, StackTrace stackTrace) =>
          _onChildStreamError(childId, completer, error, stackTrace),
    );
  }

  Future<void> _onChildDone(
    int childId,
    DefaultMontyBridge bridge,
    MontyPlatform platform,
    PluginRegistry registry,
    Completer<Object?> completer, {
    String? errorMessage,
    MontyException? errorException,
    Object? value,
    String? printOutput,
  }) async {
    final child = _children[childId];
    if (child == null) return;

    final finalState = errorMessage != null
        ? ChildFailed(
            message: errorMessage,
            exception: errorException,
            printOutput: printOutput,
          )
        : ChildCompleted(value: value, printOutput: printOutput);

    child.state.value = finalState;
    _updateChildrenSignal();

    try {
      await registry.disposeAll();
      bridge.dispose();
      await platform.dispose();
    } on Object catch (e, st) {
      logger.warning(
        'Child cleanup error (swallowed)',
        error: e,
        stackTrace: st,
        attributes: {'childId': childId},
      );
    }

    if (completer.isCompleted) return;

    if (errorMessage != null) {
      final truncated = errorMessage.length > 200
          ? '${errorMessage.substring(0, 200)}\u2026'
          : errorMessage;
      logger.debug(
        'Child failed',
        attributes: {'childId': childId, 'error': truncated},
      );
      completer.completeError(
        ChildSandboxException(
          childId: childId,
          message: errorMessage,
          exception: errorException,
        ),
        StackTrace.current,
      );
    } else {
      logger.info('Child completed', attributes: {'childId': childId});
      completer.complete(value);
    }
  }

  void _onChildStreamError(
    int childId,
    Completer<Object?> completer,
    Object error,
    StackTrace stackTrace,
  ) {
    final child = _children[childId];
    if (child != null) {
      child.state.value = ChildFailed(message: error.toString());
      _updateChildrenSignal();
    }
    logger.error(
      'Child stream error',
      error: error,
      attributes: {'childId': childId},
    );
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }

  /// Snapshots all children's current [ChildState] into [stateSignal].
  void _updateChildrenSignal() {
    state = {
      for (final entry in _children.entries) entry.key: entry.value.state.value,
    };
  }

  /// Concatenates builder + runtime prompt layers.
  ///
  /// Returns `null` when both layers are absent.
  String? _buildChildSystemPrompt(
    ChildSpawnContext context,
    String? runtimeFragment,
  ) {
    final builderFragment = systemPromptBuilder?.call(context);
    if (builderFragment == null && runtimeFragment == null) return null;

    final parts = <String>[?builderFragment, ?runtimeFragment];

    return parts.join('\n\n');
  }

  Future<Object?> _handleAwait(Map<String, Object?> args, HostContext ctx) async {
    final handle = args.intArg('handle');
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }

    return child.completer.future;
  }

  Future<Object?> _handleAwaitAll(Map<String, Object?> args, HostContext ctx) async {
    final handles = args.listOf<num>('handles').map((n) => n.toInt()).toList();

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

  Future<Object?> _handleIsAlive(Map<String, Object?> args, HostContext ctx) {
    final handle = args.intArg('handle');
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }

    return Future.value(child.isAlive);
  }

  Future<Object?> _handleFree(Map<String, Object?> args, HostContext ctx) {
    final handle = args.intArg('handle');
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
    _updateChildrenSignal();
    logger.debug('Child freed', attributes: {'childId': handle});

    return Future.value();
  }

  Future<Object?> _handleGetOutput(Map<String, Object?> args, HostContext ctx) {
    final handle = args.intArg('handle');
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }
    if (child.isAlive) {
      throw StateError(
        'Child $handle is still running. Await it before reading output.',
      );
    }

    return Future.value(child.printOutput);
  }

  Future<Object?> _handleGather(Map<String, Object?> args, HostContext ctx) async {
    final handles = args.listOf<num>('handles').map((n) => n.toInt()).toList();

    final futures = <Future<Object?>>[];
    for (final handle in handles) {
      final child = _children[handle];
      if (child == null) {
        throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
      }
      futures.add(child.completer.future);
    }

    final values = await Future.wait(futures);

    final results = <Map<String, Object?>>[];
    for (var i = 0; i < handles.length; i++) {
      results.add({
        'handle': handles[i],
        'value': values[i],
        'output': _children[handles[i]]!.printOutput,
      });
    }

    return results;
  }
}
