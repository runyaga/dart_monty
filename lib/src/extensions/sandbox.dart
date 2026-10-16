import 'dart:async';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/args.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
import 'package:dart_monty/src/runtime/runtime.dart'
    show MontyRuntime, runtimeLimits;
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
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

  /// The original [MontyError] when the error originated from Python.
  ///
  /// Null for disposal and non-Python errors.
  final MontyError? exception;

  @override
  String toString() => 'ChildSandboxException(child $childId): $message';
}

// ---------------------------------------------------------------------------
// ChildState — sealed lifecycle state for spawned children.
// ---------------------------------------------------------------------------

/// The lifecycle state of a spawned child sandbox.
///
/// Subscribe to [SandboxExtension.childrenSignal] for reactive observation:
/// ```dart
/// effect(() {
///   for (final entry in extension.childrenSignal.value.entries) {
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

  /// The original [MontyError] when the error came from Python.
  ///
  /// Null for non-Python failures.
  final MontyError? exception;

  /// Captured `print()` output, or `null` if the child produced none.
  final String? printOutput;
}

/// The child was cancelled or the parent extension was disposed
/// before completion.
final class ChildDisposed extends ChildState {
  /// Creates a [ChildDisposed].
  const ChildDisposed();
}

// ---------------------------------------------------------------------------
// Factory typedefs
// ---------------------------------------------------------------------------

/// Tracks a spawned child interpreter.
class _ChildHandle {
  _ChildHandle({
    required this.bridge,
    required this.session,
    required this.completer,
    required this.subscription,
    required this.coordinator,
    required this.workspace,
  });

  final MontyBridge bridge;
  final MontySession session;
  final Completer<MontyValue> completer;
  final StreamSubscription<BridgeEvent> subscription;
  final ExtensionCoordinator coordinator;
  final Workspace workspace;

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
    // (e.g., an extension completes pending calls with StateError).
    // The bridge/stream must still be alive to deliver the resulting errors.
    await coordinator.disposeAll();
    await subscription.cancel();
    bridge.dispose();
    await session.close();
    await workspace.dispose();
  }
}

// ---------------------------------------------------------------------------
// Schema constants for SandboxExtension host functions.
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
      name: 'files',
      type: HostParamType.map,
      isRequired: false,
      description: 'Child-relative destination to absolute parent source.',
    ),
    HostParam(
      name: 'ro_files',
      type: HostParamType.map,
      isRequired: false,
      description:
          'Read-only child-relative destination to absolute parent source.',
    ),
    HostParam(
      name: 'write_bytes_limit',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Reduce the cumulative workspace write byte limit.',
    ),
    HostParam(
      name: 'memory_usage_limit',
      type: HostParamType.integer,
      isRequired: false,
      description: 'Reduce retained workspace content plus entry bytes.',
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
    HostParam(
      name: 'collect',
      type: HostParamType.map,
      isRequired: false,
      description:
          'Child-relative source to absolute parent destination. '
          'Explicit and repeatable.',
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

/// Extension that spawns Python scripts in separate Monty interpreter
/// instances.
///
/// Each child gets its own [MontySession] and [MontyBridge]. The parent
/// Python script can spawn children with
/// `sandbox_spawn(code)` and await their results with `sandbox_await(handle)`.
///
/// Children are sandboxed: each has its own interpreter state.
/// All living children are killed when this extension is disposed.
///
/// ## Child extension and VFS inheritance
///
/// Child extensions and OS handlers are inherited from the parent
/// [ExtensionCoordinator] via [ExtensionCoordinator.spawnChild]. Extensions
/// opt into inheritance by overriding [MontyExtension.createChildInstance];
/// each child receives an independent memory workspace at `/work`.
///
/// `SandboxExtension` MUST be attached through an [ExtensionCoordinator] —
/// it uses the parent coordinator to compose the child.
class SandboxExtension extends MontyExtension {
  /// Creates a [SandboxExtension].
  ///
  /// [maxChildren] limits concurrent children (default: 16).
  /// [maxDepth] limits recursion depth if children also have SandboxExtension
  /// (default: 3). Set [currentDepth] when creating nested plugins.
  /// [childLimits] sets resource limits for child interpreters.
  SandboxExtension({
    this.maxChildren = 16,
    this.maxDepth = 3,
    this.currentDepth = 0,
    this.childLimits,
    this.sandboxBaseDir,
    this.writeBytesLimit = 8388608,
    this.memoryUsageLimit = 8388608,
  }) {
    reduceWorkspaceCap(writeBytesLimit, null);
    reduceWorkspaceCap(memoryUsageLimit, null);
    if (maxChildren < 0) throw ArgumentError.value(maxChildren, 'maxChildren');
  }

  /// Cumulative accepted workspace write bytes; explicit null is unbounded.
  // ignore: unnecessarily-public-code, approved public D4a cap field.
  final int? writeBytesLimit;

  /// Retained content plus 64 bytes per entry; explicit null is unbounded.
  // ignore: unnecessarily-public-code, approved public D4a cap field.
  final int? memoryUsageLimit;

  /// Maximum number of concurrent children.
  final int maxChildren;

  /// Maximum recursion depth for nested sandbox plugins.
  final int maxDepth;

  /// Current recursion depth.
  final int currentDepth;

  /// Resource limits applied to child interpreters.
  final ResourceLimits? childLimits;

  /// Reserved for owned native backing, pending D4b.
  /// Memory children always use the virtual cwd `/work`.
  final String? sandboxBaseDir;

  final WorkspaceTransfers _transfers = WorkspaceTransfers();
  int _pendingSpawns = 0;

  final Map<int, _ChildHandle> _children = {};
  final Signal<Map<int, ChildState>> _childrenSignal =
      signal<Map<int, ChildState>>(const {});
  int _nextId = 0;
  bool _disposed = false;

  /// Reactive snapshot of every child's [ChildState], keyed by handle.
  ///
  /// Updated whenever a child transitions state (spawn, complete, fail, free,
  /// or dispose). Subscribe via `effect` for reactive UI or monitoring:
  /// ```dart
  /// effect(() => print(extension.childrenSignal.value));
  /// ```
  ReadonlySignal<Map<int, ChildState>> get childrenSignal => _childrenSignal;

  /// Reactive count of children still in [ChildRunning] state.
  ///
  /// Derived from [childrenSignal]; updates automatically.
  ReadonlySignal<int> get aliveCountSignal => _aliveCountSignal;

  late final Computed<int> _aliveCountSignal = computed(
    () => _childrenSignal.value.values.whereType<ChildRunning>().length,
  );

  @override
  String get namespace => 'sandbox';

  /// Supported on both FFI and WASM backends.
  ///
  /// Each child runs on its own session.
  @override
  Set<MontyBackendKind> get supportedBackends => const {
    MontyBackendKind.ffi,
    MontyBackendKind.wasm,
  };

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
    await _transfers.dispose();

    final aliveCount = _children.values.where((c) => c.isAlive).length;
    logger.info(
      'Disposing SandboxExtension',
      attributes: {
        'totalChildren': _children.length,
        'aliveChildren': aliveCount,
      },
    );

    await _disposeChildren();
    _children.clear();
    _childrenSignal.value = const <int, ChildState>{};
    await super.onDispose();
    _childrenSignal.dispose();
  }

  Future<void> _disposeChildren() async {
    // Tear down all living children.
    for (final entry in _children.entries) {
      final child = entry.value;
      await child.workspace.dispose();
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
  }

  Future<MontyValue> _handleSpawn(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
    _validateSpawnRequest();

    final code = args.str('code');
    final limits = _buildChildLimits(args, ctx.parent);

    final id = _nextId++;
    final spawnContext = ChildSpawnContext(
      childId: id,
      workingDirectory: '/work',
    );

    _pendingSpawns++;
    Workspace? workspace;
    late (MontySession, MontyBridge, ExtensionCoordinator) created;
    try {
      workspace = await _transfers.copyIn(
        parent: ctx.os,
        files: workspaceMapping(args['files']),
        roFiles: workspaceMapping(args['ro_files']),
        writeBytesLimit: reduceWorkspaceCap(
          writeBytesLimit,
          args.intArgOrNull('write_bytes_limit'),
        ),
        memoryUsageLimit: reduceWorkspaceCap(
          memoryUsageLimit,
          args.intArgOrNull('memory_usage_limit'),
        ),
      );
      if (_disposed) throw StateError('SandboxExtension is disposed.');
      created = await _createChildSessionAndBridge(
        spawnContext,
        limits,
        code.length,
        ctx.os,
        workspace,
      );
    } on Object {
      await workspace?.dispose();
      rethrow;
    } finally {
      _pendingSpawns--;
    }
    final (session, bridge, childCoordinator) = created;

    // Post-await disposed check — the extension may have been disposed while
    // _createChildSessionAndBridge was in flight.
    if (_disposed) {
      bridge.dispose();
      await session.close();
      await childCoordinator.disposeAll();
      await workspace.dispose();
      throw StateError('SandboxExtension was disposed during child spawn.');
    }

    final completer = Completer<MontyValue>();
    completer.future.ignore();
    logger.info(
      'Child spawned',
      attributes: {'childId': id, 'depth': currentDepth},
    );

    final stream = (bridge as SessionBridge).executeWith(code, cwd: '/work');
    final subscription = _setupChildListener(
      bridge: bridge,
      session: session,
      coordinator: childCoordinator,
      completer: completer,
      childId: id,
      stream: stream,
      parent: ctx.parent,
    );

    _children[id] = _ChildHandle(
      bridge: bridge,
      session: session,
      completer: completer,
      subscription: subscription,
      coordinator: childCoordinator,
      workspace: workspace,
    );
    _updateChildrenSignal();

    return MontyInt(id);
  }

  /// Throws if the extension is disposed or resource limits are exceeded.
  void _validateSpawnRequest() {
    if (_disposed) throw StateError('SandboxExtension is disposed.');
    if (currentDepth >= maxDepth) {
      logger.warning(
        'Spawn rejected: depth limit',
        attributes: {'currentDepth': currentDepth, 'maxDepth': maxDepth},
      );
      throw StateError('Maximum sandbox recursion depth ($maxDepth) exceeded.');
    }
    final aliveCount = _children.length + _pendingSpawns;
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
  ResourceLimits? _buildChildLimits(
    Map<String, MontyValue> args,
    HostParentRef? parent,
  ) {
    final effective =
        childLimits ?? (parent is MontyRuntime ? runtimeLimits(parent) : null);
    final timeoutMs = args.intArgOrNull('timeout_ms');
    final memoryBytes = args.intArgOrNull('memory_bytes');
    if (timeoutMs == null && memoryBytes == null) return effective;

    return _reduceLimits(
      effective ?? const ResourceLimits(),
      timeoutMs,
      memoryBytes,
    );
  }

  /// Checks out the child's session with [limits]; built in D1-8.
  Future<MontySession> _checkoutChildSession(ResourceLimits? limits) =>
      throw UnimplementedError('D1-8');

  /// Checks out the child session, creates its bridge, wires extensions, and
  /// attaches the coordinator.
  ///
  /// Disposes all partially-created resources on failure.
  Future<(MontySession, MontyBridge, ExtensionCoordinator)>
  _createChildSessionAndBridge(
    ChildSpawnContext spawnContext,
    ResourceLimits? limits,
    int codeLength,
    OsHandler? parentOsOverride,
    Workspace workspace,
  ) async {
    MontySession? session;
    MontyBridge? bridge;
    ExtensionCoordinator? childCoordinator;
    try {
      try {
        session = await _checkoutChildSession(limits);
      } on Object catch (e, st) {
        logger.error(
          'Child session checkout failed',
          error: e,
          stackTrace: st,
          attributes: {'phase': 'checkout'},
        );
        rethrow;
      }
      bridge = MontyBridge(
        session: session,
        logger: logger.child('child.${spawnContext.childId}'),
      );
      logger.debug(
        'Child bridge created',
        attributes: {
          'codeLength': codeLength,
          if (limits != null) 'limits': _formatLimits(limits),
        },
      );

      childCoordinator = await _wireChildExtensions(
        spawnContext,
        bridge,
        parentOsOverride,
        workspace,
      );
    } on Object {
      if (bridge != null) bridge.dispose();
      if (session != null) await session.close();
      if (childCoordinator != null) await childCoordinator.disposeAll();
      rethrow;
    }

    return (session, bridge, childCoordinator);
  }

  /// Creates and attaches a child [ExtensionCoordinator] by delegating to
  /// [ExtensionCoordinator.spawnChild] on the parent coordinator. Child
  /// extensions are composed via [MontyExtension.createChildInstance]; the
  /// child OS handler owns its independent workspace.
  ///
  /// Relies on [coordinatorOf] — i.e., this extension must be attached
  /// through an [ExtensionCoordinator].
  Future<ExtensionCoordinator> _wireChildExtensions(
    ChildSpawnContext spawnContext,
    MontyBridge bridge,
    OsHandler? parentOsOverride,
    Workspace workspace,
  ) async {
    try {
      final childCoordinator = await coordinatorOf(this).spawnChild(
        context: spawnContext,
        bridge: bridge,
        workspace: workspace,
        baseOs: parentOsOverride,
      );
      logger.debug(
        'Child extensions attached',
        attributes: {'extensionCount': childCoordinator.extensions.length},
      );

      return childCoordinator;
    } on Object catch (e, st) {
      logger.error(
        'Child extension inheritance failed',
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
    required MontyBridge bridge,
    required MontySession session,
    required ExtensionCoordinator coordinator,
    required Completer<MontyValue> completer,
    required int childId,
    required Stream<BridgeEvent> stream,
    required HostParentRef? parent,
  }) {
    String? errorMessage;
    MontyError? errorException;
    MontyValue value = const MontyNone();
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
          value = event.montyValue ?? const MontyNone();
          printOutput = event.printOutput;
        }
      },
      onDone: () => unawaited(
        _onChildDone(
          childId,
          bridge,
          session,
          coordinator,
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
    MontyBridge bridge,
    MontySession session,
    ExtensionCoordinator coordinator,
    Completer<MontyValue> completer, {
    required String? errorMessage,
    required MontyError? errorException,
    required MontyValue value,
    required String? printOutput,
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
      await coordinator.disposeAll();
      bridge.dispose();
      await session.close();
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
    Completer<MontyValue> completer,
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

  /// Snapshots all children's current [ChildState] into [childrenSignal].
  void _updateChildrenSignal() {
    _childrenSignal.value = {
      for (final entry in _children.entries) entry.key: entry.value.state.value,
    };
  }

  Future<MontyValue> _handleAwait(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
    final handle = args.intArg('handle');
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }

    final result = await child.completer.future;
    await _transfers.collect(
      child.workspace,
      workspaceMapping(args['collect']),
    );

    return result;
  }

  Future<MontyValue> _handleAwaitAll(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
    final handles = args
        .listArg('handles')
        .map((n) => (n as MontyInt).value)
        .toList();

    final futures = <Future<MontyValue>>[];
    for (final handle in handles) {
      final child = _children[handle];
      if (child == null) {
        throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
      }
      futures.add(child.completer.future);
    }

    return MontyList(await Future.wait(futures));
  }

  Future<MontyValue> _handleIsAlive(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) {
    final handle = args.intArg('handle');
    final child = _children[handle];
    if (child == null) {
      throw ArgumentError.value(handle, 'handle', 'Unknown child handle.');
    }

    return Future.value(MontyBool(child.isAlive));
  }

  Future<MontyValue> _handleFree(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
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
    await child.workspace.dispose();
    _children.remove(handle);
    _updateChildrenSignal();
    logger.debug('Child freed', attributes: {'childId': handle});

    return const MontyNone();
  }

  Future<MontyValue> _handleGetOutput(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) {
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

    return Future.value(MontyValue.fromDart(child.printOutput));
  }

  Future<MontyValue> _handleGather(
    Map<String, MontyValue> args,
    HostContext ctx,
  ) async {
    final handles = args
        .listArg('handles')
        .map((n) => (n as MontyInt).value)
        .toList();

    final futures = <Future<MontyValue>>[];
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

    return MontyValue.fromDart(results);
  }
}

/// Applies guest reductions to the already selected child limits.
ResourceLimits _reduceLimits(
  ResourceLimits effective,
  int? timeoutMs,
  int? memoryBytes,
) {
  final timeout = timeoutMs == null ? null : Duration(milliseconds: timeoutMs);
  _checkReduction(
    timeout?.inMicroseconds,
    effective.maxFeedDuration?.inMicroseconds,
    'timeout_ms',
  );
  _checkReduction(memoryBytes, effective.maxMemory, 'memory_bytes');

  return ResourceLimits(
    maxFeedDuration: timeout ?? effective.maxFeedDuration,
    maxMemory: memoryBytes ?? effective.maxMemory,
    maxRecursionDepth: effective.maxRecursionDepth,
    maxTurnDuration: effective.maxTurnDuration,
    gcInterval: effective.gcInterval,
    maxSuspensions: effective.maxSuspensions,
    maxTotalSleep: effective.maxTotalSleep,
  );
}

void _checkReduction(int? requested, int? ceiling, String name) {
  if (requested == null) return;
  if (requested < 0 || (ceiling != null && requested > ceiling)) {
    throw ArgumentError('$name must only reduce the configured limit');
  }
}

/// The fields of [limits] that are set, for a log line.
String _formatLimits(ResourceLimits limits) => [
  if (limits.maxFeedDuration != null)
    'maxFeedDuration: ${limits.maxFeedDuration}',
  if (limits.maxTurnDuration != null)
    'maxTurnDuration: ${limits.maxTurnDuration}',
  if (limits.maxMemory != null) 'maxMemory: ${limits.maxMemory}',
  if (limits.gcInterval != null) 'gcInterval: ${limits.gcInterval}',
  if (limits.maxRecursionDepth != null)
    'maxRecursionDepth: ${limits.maxRecursionDepth}',
  if (limits.maxSuspensions != null) 'maxSuspensions: ${limits.maxSuspensions}',
  if (limits.maxTotalSleep != null) 'maxTotalSleep: ${limits.maxTotalSleep}',
].join(', ');
