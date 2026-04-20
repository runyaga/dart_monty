import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';

/// The narrow capability surface passed to [MontyExtension.onAttach].
///
/// Exposes only what extensions legitimately need during attachment: read-only
/// access to peer extensions' registered [schemas] and the imperative escape
/// hatch [registerOs] for OS contribution when the declarative
/// [MontyExtension.osContribution] path is not expressive enough.
///
/// This interface intentionally hides the underlying `MontyBridge`: extensions
/// have no business calling `execute`, `dispose`, or any other runtime
/// method on the bridge itself.
abstract interface class AttachContext {
  /// Schemas of every host function registered so far, including those
  /// contributed by other extensions that attached before this one.
  ///
  /// Useful for extensions that need to validate the presence of a peer's
  /// functions at attach time (fail loudly if a dependency is missing).
  List<HostFunctionSchema> get schemas;

  /// Registers an [OsCallHandler] imperatively.
  ///
  /// Most extensions should prefer the declarative [MontyExtension.osContribution]
  /// path, which participates in `ExtensionCoordinator`'s prefix merging and
  /// collision checks. Use [registerOs] only when no declarative path works.
  void registerOs(OsCallHandler handler);
}
