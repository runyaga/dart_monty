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
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime.dart'
    show MontyRuntime, captureChildContext, runtimeLimits;
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty/src/workspace/workspace.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:signals_core/signals_core.dart';

/// Retains a child failure and its structured Python error when available.
class _ChildSandboxException implements Exception {
  /// Creates a [_ChildSandboxException].
  const _ChildSandboxException({
    required this.childId,
    required this.message,
    this.exception,
  });

  /// The child handle that failed.
  final int childId;

  /// Human-readable error message.
  final String message;

  /// Preserves the Python error when one caused the failure.
  final MontyError? exception;

  @override
  String toString() => 'ChildSandboxException(child $childId): $message';
}

// ---------------------------------------------------------------------------
// _ChildState is the sealed lifecycle state for spawned children.
// ---------------------------------------------------------------------------

/// Private lifecycle state of a retained child.
sealed class _ChildState {
  /// Creates a [_ChildState].
  const _ChildState();
}

/// The child is still executing.
final class _ChildRunning extends _ChildState {
  /// Creates a [_ChildRunning].
  const _ChildRunning();
}

/// The child finished successfully.
final class _ChildCompleted extends _ChildState {
  /// Creates a [_ChildCompleted].
  const _ChildCompleted({required this.value, required this.printOutput});

  /// The typed Python return value.
  final MontyValue value;

  /// Captured `print()` output, or `null` if the child produced none.
  final String? printOutput;
}

/// The child finished with an error.
final class _ChildFailed extends _ChildState {
  /// Creates a [_ChildFailed].
  const _ChildFailed({
    required this.message,
    required this.exception,
    required this.printOutput,
  });

  /// Human-readable error description.
  final String message;

  /// Preserves the Python error when one caused the failure.
  final MontyError? exception;

  /// Captured `print()` output, or `null` if the child produced none.
  final String? printOutput;
}

/// Marks a child stopped before completion.
final class _ChildDisposed extends _ChildState {
  /// Creates a [_ChildDisposed].
  const _ChildDisposed();
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
    required this.finish,
    required this.coordinator,
    required this.workspace,
  });

  final MontyBridge bridge;
  final MontySession session;
  final Completer<MontyValue> completer;
  StreamSubscription<BridgeEvent>? subscription;
  final void Function() finish;
  final ExtensionCoordinator coordinator;
  final Workspace workspace;

  /// Tracks the child lifecycle from the running state.
  final Signal<_ChildState> state = signal(const _ChildRunning());
  Future<void>? _cleanup;

  Future<void>? _release;

  /// Whether the child is still executing.
  bool get isAlive => state.value is _ChildRunning;

  /// Captured `print()` output from a completed child, or `null`.
  String? get printOutput => switch (state.value) {
    _ChildCompleted(printOutput: final output) ||
    _ChildFailed(printOutput: final output) => output,
    _ => null,
  };

  Future<void> cleanup() => _cleanup ??= _cleanupExecution();

  Future<void> release() => _release ??= _releaseAll();

  Future<void> _cleanupExecution() async {
    finish();
    // Every resource gets an attempt, even when an earlier owner throws.
    for (final close in <FutureOr<void> Function()>[
      coordinator.disposeAll,
      () => subscription?.cancel(),
      bridge.dispose,
      session.close,
    ]) {
      try {
        await close();
      } on Object {
        /* terminal result remains primary */
      }
    }
  }

  Future<void> _releaseAll() async {
    await cleanup();
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
      'Release a child handle and free its resources. '
      'Cancels a running child; repeated release is harmless.',
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

/// Owns isolated child sessions, extension attachments, and workspaces.
class SandboxExtension extends MontyExtension {
  /// Configures child admission, nesting, resource, and workspace limits.
  SandboxExtension({
    this.maxChildren = 16,
    this.maxDepth = 3,
    this.currentDepth = 0,
    this.childLimits,
    this.childExternalModules,
    this.sandboxBaseDir,
    this.writeBytesLimit = 8388608,
    this.memoryUsageLimit = 8388608,
  }) {
    reduceWorkspaceCap(writeBytesLimit, null);
    reduceWorkspaceCap(memoryUsageLimit, null);
    if (maxChildren < 0) throw ArgumentError.value(maxChildren, 'maxChildren');
  }

  /// Limits cumulative accepted workspace writes to 8 MiB by default, with
  /// explicit null selecting no limit.
  // ignore: unnecessarily-public-code, approved public D4a cap field.
  final int? writeBytesLimit;

  /// Limits retained content plus 64 bytes per entry to 8 MiB by default, with
  /// explicit null selecting no limit.
  // ignore: unnecessarily-public-code, approved public D4a cap field.
  final int? memoryUsageLimit;

  /// Limits admitted handles until they are freed and defaults to 16.
  final int maxChildren;

  /// Limits nested sandboxes to three levels by default.
  final int maxDepth;

  /// Records the current recursion depth and defaults to the root level.
  final int currentDepth;

  /// Overrides inherited child limits. Without one, children use runtime
  /// limits. Guest timeout and memory requests may only reduce those limits.
  final ResourceLimits? childLimits;

  /// Grants external modules to children. Without one, children get no external
  /// modules. Parent runtime modules are never inherited.
  final Map<String, Object?>? childExternalModules;

  /// Selects owned native backing on the VM that remains available until free
  /// or disposal. Web builds reject this setting with [UnsupportedError].
  final String? sandboxBaseDir;

  final WorkspaceTransfers _transfers = WorkspaceTransfers();
  int _pendingSpawns = 0;
  final Set<Future<void>> _spawns = {};
  Future<void>? _disposeFuture;

  final Map<int, _ChildHandle> _children = {};
  final Signal<Map<int, _ChildState>> _childrenSignal =
      signal<Map<int, _ChildState>>(const {});
  int _nextId = 0;
  bool _disposed = false;

  @override
  String get namespace => 'sandbox';

  /// Supports independent child sessions on native and browser backends.
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
  // ignore: must_call_super, _dispose calls super once inside the joined future.
  Future<void> onDispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _logChild(
      () => logger.info(
        'Disposing SandboxExtension',
        attributes: {
          'totalChildren': _children.length,
          'aliveChildren': _children.values
              .where((child) => child.isAlive)
              .length,
        },
      ),
    );
    await _transfers.dispose();
    await Future.wait(_spawns.toList());
    await Future.wait(
      _children.entries.map((entry) async {
        await _cancelChild(entry.key, entry.value);
        await entry.value.release();
      }),
    );
    _children.clear();
    _childrenSignal.value = const <int, _ChildState>{};
    await super.onDispose();
    _childrenSignal.dispose();
  }

  Future<void> _cancelChild(int id, _ChildHandle child) async {
    if (child.isAlive) {
      child.state.value = const _ChildDisposed();
      _updateChildrenSignal();
    }
    await child.cleanup();
    if (!child.completer.isCompleted) {
      child.completer.completeError(
        _ChildSandboxException(childId: id, message: 'disposed with parent'),
        StackTrace.current,
      );
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

    final parent = ctx.parent;
    if (parent is! MontyRuntime) {
      throw StateError('SandboxExtension requires an owning MontyRuntime');
    }
    final execution = captureChildContext(parent, ctx, limits);
    _pendingSpawns++;
    final spawning = Completer<void>();
    _spawns.add(spawning.future);
    Workspace? workspace;
    MontySession? session;
    SessionBridge? bridge;
    ExtensionCoordinator? childCoordinator;
    try {
      workspace = await _transfers.copyIn(
        parent: ctx.os,
        sandboxBaseDir: sandboxBaseDir,
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
      if (_disposed || !execution.isValid) {
        throw StateError('Child origin is disposed');
      }
      try {
        session = await execution.checkout(
          externalModules: childExternalModules,
        );
      } on Object catch (error, stack) {
        logger.error(
          'Child session checkout failed',
          error: error,
          stackTrace: stack,
          attributes: {'phase': 'checkout'},
        );
        rethrow;
      }
      if (_disposed || !execution.isValid) {
        throw StateError('Child origin is disposed');
      }
      bridge = SessionBridge(
        session: session,
        runtime: parent,
        subExecute: execution.subExecute,
        logger: logger.child('child.$id'),
      )..workspace = workspace;
      _logChild(
        () => logger.debug(
          'Child bridge created',
          attributes: {'codeLength': code.length},
        ),
      );
      childCoordinator = await coordinatorOf(this).spawnChild(
        context: spawnContext,
        bridge: bridge,
        workspace: workspace,
        baseOs: ctx.os,
      );
      if (_disposed || !execution.isValid) {
        throw StateError('Child origin is disposed');
      }
      final completer = Completer<MontyValue>();
      completer.future.ignore();
      final child = _ChildHandle(
        bridge: bridge,
        session: session,
        completer: completer,
        coordinator: childCoordinator,
        workspace: workspace,
        finish: execution.finish,
      );
      final stream = bridge.executeWith(
        code,
        cwd: '/work',
        cancelToken: execution.token,
      );
      _children[id] = child;
      child.subscription = _setupChildListener(
        childId: id,
        stream: stream,
        emit: execution.emit,
      );
      _updateChildrenSignal();
      unawaited(_watchCancellation(id, child, execution.token));
      _logChild(
        () => logger.info(
          'Child spawned',
          attributes: {'childId': id, 'depth': currentDepth},
        ),
      );

      return MontyInt(id);
    } on Object {
      execution.finish();
      await _closeUnpublishedChild(
        childCoordinator,
        bridge,
        session,
        workspace,
      );
      rethrow;
    } finally {
      _pendingSpawns--;
      _spawns.remove(spawning.future);
      spawning.complete();
    }
  }

  Future<void> _watchCancellation(
    int id,
    _ChildHandle child,
    CancelToken token,
  ) async {
    await Future.any([token.future, _settledChild(child.completer.future)]);
    if (child.isAlive && token.isCancelled) await _cancelChild(id, child);
  }

  /// Throws if the extension is disposed or resource limits are exceeded.
  void _validateSpawnRequest() {
    if (_disposed) throw StateError('SandboxExtension is disposed.');
    if (currentDepth >= maxDepth) {
      _logChild(
        () => logger.warning(
          'Spawn rejected: depth limit',
          attributes: {'currentDepth': currentDepth, 'maxDepth': maxDepth},
        ),
      );
      throw StateError('Maximum sandbox recursion depth ($maxDepth) exceeded.');
    }
    final aliveCount = _children.length + _pendingSpawns;
    if (aliveCount >= maxChildren) {
      _logChild(
        () => logger.warning(
          'Spawn rejected: concurrency limit',
          attributes: {'alive': aliveCount, 'maxChildren': maxChildren},
        ),
      );
      throw StateError('Maximum concurrent children ($maxChildren) reached.');
    }
  }

  /// Selects whole-object limits, then applies guest reductions.
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

  StreamSubscription<BridgeEvent> _setupChildListener({
    required int childId,
    required Stream<BridgeEvent> stream,
    required void Function(String, BridgeEvent) emit,
  }) {
    String? error;
    MontyError? exception;
    MontyValue value = const MontyNone();
    String? output;

    return stream.listen(
      (event) {
        emit('$childId', event);
        if (event is BridgeRunError) {
          error = event.message;
          exception = event.exception;
          output = event.printOutput;
        } else if (event is BridgeRunFinished) {
          value = event.montyValue ?? const MontyNone();
          output = event.printOutput;
        }
      },
      onDone: () => unawaited(
        _onChildDone(
          childId,
          errorMessage: error,
          errorException: exception,
          value: value,
          printOutput: output,
        ),
      ),
      onError: (Object streamError, StackTrace stack) => unawaited(
        _onChildDone(
          childId,
          errorMessage: streamError.toString(),
          errorException: null,
          value: const MontyNone(),
          printOutput: output,
        ),
      ),
    );
  }

  Future<void> _onChildDone(
    int childId, {
    required String? errorMessage,
    required MontyError? errorException,
    required MontyValue value,
    required String? printOutput,
  }) async {
    final child = _children[childId];
    if (child == null || !child.isAlive) return;
    child.state.value = errorMessage != null
        ? _ChildFailed(
            message: errorMessage,
            exception: errorException,
            printOutput: printOutput,
          )
        : _ChildCompleted(value: value, printOutput: printOutput);
    _updateChildrenSignal();
    await child.cleanup();
    if (child.completer.isCompleted) return;
    if (errorMessage != null) {
      _logChild(
        () => logger.debug(
          'Child failed',
          attributes: {
            'childId': childId,
            'error': errorMessage.length > 200
                ? '${errorMessage.substring(0, 200)}…'
                : errorMessage,
          },
        ),
      );
      child.completer.completeError(
        _ChildSandboxException(
          childId: childId,
          message: errorMessage,
          exception: errorException,
        ),
        StackTrace.current,
      );
    } else {
      _logChild(
        () => logger.info('Child completed', attributes: {'childId': childId}),
      );
      child.completer.complete(value);
    }
  }

  /// Snapshots all children's current [_ChildState] into the private signal.
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
    if (child == null) return const MontyNone();
    await _cancelChild(handle, child);
    await child.release();
    _children.remove(handle);
    _updateChildrenSignal();
    _logChild(
      () => logger.debug('Child freed', attributes: {'childId': handle}),
    );

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

Future<void> _settledChild(Future<MontyValue> future) async {
  try {
    await future;
  } on Object {
    /* The await/gather caller observes this error. */
  }
}

void _logChild(void Function() write) {
  try {
    write();
  } on Object {
    /* Logging cannot interrupt child ownership. */
  }
}

Future<void> _closeUnpublishedChild(
  ExtensionCoordinator? childCoordinator,
  SessionBridge? bridge,
  MontySession? session,
  Workspace? workspace,
) async {
  for (final close in <FutureOr<void> Function()>[
    () => childCoordinator?.disposeAll(),
    () => bridge?.dispose(),
    () => session?.close(),
    () => workspace?.dispose(),
  ]) {
    try {
      await close();
    } on Object {
      /* preserve spawn error */
    }
  }
}
