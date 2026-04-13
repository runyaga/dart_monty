import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/plugin_registry.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';
import 'package:meta/meta.dart';

// ---------------------------------------------------------------------------
// ExecuteOutcome — sealed terminal result for onExecuteEnd.
// ---------------------------------------------------------------------------

/// Terminal outcome of a single [MontyBridge.execute] call.
///
/// Passed to [MontyPlugin.onExecuteEnd] after the stream exhausts.
/// Use exhaustive pattern-matching to distinguish success from failure:
///
/// ```dart
/// @override
/// Future<void> onExecuteEnd(ExecuteOutcome outcome) async {
///   switch (outcome) {
///     case ExecuteSuccess(:final event):
///       log.info('run finished', attributes: {'runId': event.runId});
///     case ExecuteFailure(:final event):
///       log.warning('run failed', attributes: {'error': event.message});
///   }
/// }
/// ```
sealed class ExecuteOutcome {
  const ExecuteOutcome();
}

/// Outcome for a run that completed with [BridgeRunFinished].
final class ExecuteSuccess extends ExecuteOutcome {
  /// Creates an [ExecuteSuccess] wrapping [event].
  const ExecuteSuccess(this.event);

  /// The terminal finished event.
  final BridgeRunFinished event;
}

/// Outcome for a run that ended with [BridgeRunError].
final class ExecuteFailure extends ExecuteOutcome {
  /// Creates an [ExecuteFailure] wrapping [event].
  const ExecuteFailure(this.event);

  /// The terminal error event.
  final BridgeRunError event;
}

// ---------------------------------------------------------------------------
// ChildSpawnContext
// ---------------------------------------------------------------------------

/// Context passed to [MontyPlugin.createChildInstance] when a child sandbox
/// is spawned.
///
/// Carries the child's unique [childId] and an optional [workingDirectory]
/// that the consumer can use for per-child filesystem isolation.
class ChildSpawnContext {
  /// Creates a [ChildSpawnContext].
  const ChildSpawnContext({required this.childId, this.workingDirectory});

  /// Unique identifier for this child within the parent `SandboxPlugin`.
  final int childId;

  /// Per-child working directory path, or `null` if the parent did not
  /// configure `SandboxPlugin.sandboxBaseDir`.
  ///
  /// This is a computed path string only — actual directory creation is the
  /// consumer's responsibility (e.g., in `FsPlugin.createChildInstance`).
  final String? workingDirectory;
}

// ---------------------------------------------------------------------------
// MontyPlugin
// ---------------------------------------------------------------------------

/// Extension point for providing host functions to a [MontyBridge].
///
/// Each plugin declares a unique [namespace], a set of [functions], and
/// optional lifecycle hooks ([onRegister], [onDispose]).
///
/// ## Registry injection
///
/// After `PluginRegistry.attachTo` runs, [registry] is set to the owning
/// registry. Use [sibling] for cross-plugin lookups inside [onRegister]:
///
/// ```dart
/// @override
/// Future<void> onRegister(MontyBridge bridge) async {
///   final other = sibling<OtherPlugin>();
///   other?.configure(this);
/// }
/// ```
///
/// Accessing [registry] or calling [sibling] before `attachTo` is called
/// throws a `LateInitializationError`.
///
/// ## OS contributions
///
/// Plugins that need to intercept OS calls return a prefix map from
/// [osContribution]. `PluginRegistry.attachTo` merges contributions from all
/// plugins, throws [StateError] if two plugins claim the same prefix, and
/// calls `bridge.registerOs` with the composed provider:
///
/// ```dart
/// @override
/// Map<String, OsProvider>? get osContribution => {
///   'Path.': _myFsProvider,
///   'os.getcwd': _myFsProvider,
/// };
/// ```
///
/// ## Execution hooks
///
/// Override [onExecuteStart] and [onExecuteEnd] (and set [hasExecuteHooks]
/// to `true`) to observe every `bridge.execute()` call:
///
/// ```dart
/// @override
/// bool get hasExecuteHooks => true;
///
/// @override
/// Future<void> onExecuteStart(String code) async {
///   _timer = Stopwatch()..start();
/// }
///
/// @override
/// Future<void> onExecuteEnd(ExecuteOutcome outcome) async {
///   _timer.stop();
///   log.info('elapsed', attributes: {'ms': _timer.elapsedMilliseconds});
/// }
/// ```
abstract class MontyPlugin {
  /// Unique namespace prefix (e.g., `"df"`, `"chart"`, `"sqlite"`).
  String get namespace;

  /// Attachment priority — higher values attach first and dispose last.
  ///
  /// `PluginRegistry.attachTo` sorts plugins in descending priority order
  /// before calling [onRegister]. Equal-priority plugins preserve insertion
  /// order (stable sort). Default is `0`.
  ///
  /// Use a positive value to run [onRegister] early (e.g., a logging/tracing
  /// plugin that other plugins depend on). Use a negative value to run late
  /// (e.g., a plugin that wraps peers it discovers via the bridge).
  int get priority => 0;

  /// Logger for this plugin, injected by `PluginRegistry` during attachment.
  ///
  /// Plugins should use this for all logging — never create loggers
  /// independently via `LogManager.instance.getLogger()`.
  ///
  /// Defaults to [NullBridgeLogger] (silent) until the registry sets it.
  BridgeLogger logger = const NullBridgeLogger();

  /// The owning registry, injected during [PluginRegistry.attachTo].
  ///
  /// Use [sibling] as the preferred API for cross-plugin lookups.
  /// Accessing this field before `attachTo` has been called throws a
  /// `LateInitializationError`.
  late PluginRegistry registry;

  /// Returns the first attached plugin of type [T], or `null` if none exists.
  ///
  /// Searches [PluginRegistry.plugins] in registration order. Requires that
  /// [registry] has been injected (i.e., `attachTo` was called).
  T? sibling<T extends MontyPlugin>() {
    for (final p in registry.plugins) {
      if (p is T) return p;
    }

    return null;
  }

  /// Human-readable description for LLM system prompt.
  ///
  /// Return `null` if the plugin has no additional prompt context beyond
  /// its function schemas.
  String? get systemPromptContext => null;

  /// OS call prefix contributions for this plugin.
  ///
  /// Each key is an operation-name prefix (e.g., `'Path.'`, `'os.'`); the
  /// value is the [OsProvider] that handles those operations.
  ///
  /// `PluginRegistry.attachTo` merges contributions from all plugins and
  /// throws [StateError] if two plugins claim the same prefix. Returns `null`
  /// (the default) if this plugin does not intercept OS calls.
  Map<String, OsProvider>? get osContribution => null;

  /// Host functions this plugin provides.
  List<HostFunction> get functions;

  /// Called when attached to a bridge.
  @mustCallSuper
  Future<void> onRegister(MontyBridge bridge) async {
    // Default no-op.
  }

  /// Called when session ends. Must be idempotent.
  @mustCallSuper
  Future<void> onDispose() async {
    // Default no-op.
  }

  /// Creates a fresh instance of this plugin for a child sandbox.
  ///
  /// Override to opt into automatic child inheritance via `SandboxPlugin`.
  /// Return `null` (the default) to exclude this plugin from children.
  ///
  /// The returned instance must be independent — it will be registered on a
  /// separate [MontyBridge] and disposed with the child.
  ///
  /// [context] carries the child's ID and optional per-child working
  /// directory. Plugins that need filesystem isolation (e.g., `FsPlugin`)
  /// can use [ChildSpawnContext.workingDirectory] to create a private
  /// directory for the child.
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) => null;

  /// Returns `true` if this plugin overrides [wrapExecuteStream].
  ///
  /// `PluginRegistry` uses this opt-in flag to skip no-op wrapper
  /// registration. Override to return `true` when [wrapExecuteStream]
  /// is also overridden.
  bool get hasStreamWrapper => false;

  /// Returns `true` if this plugin overrides [onExecuteStart] or
  /// [onExecuteEnd].
  ///
  /// `PluginRegistry` uses this opt-in flag to avoid registering a no-op
  /// wrapper. Override to return `true` when either hook is overridden.
  bool get hasExecuteHooks => false;

  /// Called before the first event of each [MontyBridge.execute] call.
  ///
  /// [code] is the Python source being executed. Override to start timers,
  /// record metrics, or set up per-run state.
  ///
  /// Only invoked when [hasExecuteHooks] returns `true`.
  Future<void> onExecuteStart(String code) async {
    // Default no-op.
  }

  /// Called after the bridge stream exhausts for each [MontyBridge.execute]
  /// call.
  ///
  /// [outcome] is the terminal event — either [ExecuteSuccess] or
  /// [ExecuteFailure]. Override to stop timers, flush metrics, or clean up
  /// per-run state.
  ///
  /// Only invoked when [hasExecuteHooks] returns `true` and the stream
  /// contained a terminal event.
  Future<void> onExecuteEnd(ExecuteOutcome outcome) async {
    // Default no-op.
  }

  /// Wraps the execution stream produced by `DefaultMontyBridge.execute`.
  ///
  /// Called by `DefaultMontyBridge.execute` after the stream is created.
  /// Plugins that need to observe or transform the stream override this and
  /// set [hasStreamWrapper] to `true`.
  ///
  /// The default is a passthrough — return [stream] unchanged.
  ///
  /// Implementations must not swallow events. Map or tap and forward each
  /// event. Return a broadcast stream only if [stream] is already broadcast.
  Stream<BridgeEvent> wrapExecuteStream(
    String code,
    Stream<BridgeEvent> stream,
  ) => stream;
}
