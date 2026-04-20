import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';

/// The narrow capability surface passed to [MontyPlugin.onRegister].
///
/// Exposes only what plugins legitimately need during attachment: read-only
/// access to peer plugins' registered [schemas] and the imperative escape
/// hatch [registerOs] for OS contribution when the declarative
/// [MontyPlugin.osContribution] path is not expressive enough.
///
/// This interface intentionally hides the underlying `MontyBridge`: plugins
/// have no business calling `execute`, `dispose`, or any other runtime
/// method on the bridge itself.
abstract interface class PluginHost {
  /// Schemas of every host function registered so far, including those
  /// contributed by other plugins that attached before this one.
  ///
  /// Useful for plugins that need to validate the presence of a peer's
  /// functions at attach time (fail loudly if a dependency is missing).
  List<HostFunctionSchema> get schemas;

  /// Registers an [OsCallHandler] imperatively.
  ///
  /// Most plugins should prefer the declarative [MontyPlugin.osContribution]
  /// path, which participates in `PluginRegistry`'s prefix merging and
  /// collision checks. Use [registerOs] only when no declarative path works.
  void registerOs(OsCallHandler handler);
}
