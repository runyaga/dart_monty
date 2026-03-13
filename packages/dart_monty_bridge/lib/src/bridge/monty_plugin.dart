import 'package:dart_monty_bridge/src/bridge/host_function.dart';
import 'package:dart_monty_bridge/src/bridge/monty_bridge.dart';
import 'package:meta/meta.dart';

/// Extension point for providing host functions to a [MontyBridge].
///
/// Each plugin declares a unique [namespace], a set of [functions], and
/// optional lifecycle hooks ([onRegister], [onDispose]).
abstract class MontyPlugin {
  /// Unique namespace prefix (e.g., "df", "chart", "sqlite").
  String get namespace;

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
  MontyPlugin? createChildInstance() => null;
}
