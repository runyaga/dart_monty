import 'package:dart_monty_bridge/src/bridge/host_function.dart';
import 'package:dart_monty_bridge/src/bridge/monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:meta/meta.dart';

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

/// Extension point for providing host functions to a [MontyBridge].
///
/// Each plugin declares a unique [namespace], a set of [functions], and
/// optional lifecycle hooks ([onRegister], [onDispose]).
///
/// {@category Plugins}
abstract class MontyPlugin {
  /// Unique namespace prefix (e.g., "df", "chart", "sqlite").
  String get namespace;

  /// Logger for this plugin, injected by `PluginRegistry` during attachment.
  ///
  /// Plugins should use this for all logging — never create loggers
  /// independently via `LogManager.instance.getLogger()`.
  ///
  /// Defaults to [NullBridgeLogger] (silent) until the registry sets it.
  BridgeLogger logger = const NullBridgeLogger();

  /// Human-readable description for LLM system prompt.
  ///
  /// Return `null` if the plugin has no additional prompt context beyond
  /// its function schemas.
  String? get systemPromptContext => null;

  /// Host functions this plugin provides.
  List<HostFunction> get functions;

  /// Called when attached to a bridge.
  @mustCallSuper
  Future<void> onRegister(MontyBridge bridge) async {}

  /// Called when session ends. Must be idempotent.
  @mustCallSuper
  Future<void> onDispose() async {}

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
}
