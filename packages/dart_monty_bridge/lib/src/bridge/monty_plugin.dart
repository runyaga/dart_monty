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

  /// Python code to prepend to every session using this plugin.
  ///
  /// Use this to provide convenience wrapper functions that call the
  /// plugin's host functions. The prelude is evaluated once on session
  /// creation, before any user code runs.
  ///
  /// Must be valid Monty Python (no for-in, no f-strings, no imports).
  /// Returns empty string by default (no prelude).
  String get pythonPrelude => '';

  /// Host functions this plugin provides.
  List<HostFunction> get functions;

  /// Called when attached to a bridge.
  @mustCallSuper
  Future<void> onRegister(MontyBridge bridge) async {}

  /// Called when session ends. Must be idempotent.
  @mustCallSuper
  Future<void> onDispose() async {}
}
