import 'package:dart_monty_bridge/src/bridge/monty_plugin.dart';
import 'package:meta/meta.dart';

/// A typed, lazy reference to a sibling [MontyPlugin] in the same registry.
///
/// Declared as a field on a [CompositePlugin] and resolved automatically
/// by the `PluginRegistry` during `PluginRegistry.attachTo`.
///
/// ```dart
/// class BudgetPlugin extends MontyPlugin with CompositePlugin {
///   final memoryRef = PluginRef<MemoryPlugin>();
///   @override List<PluginRef<MontyPlugin>> get dependencies => [memoryRef];
/// }
/// ```
class PluginRef<T extends MontyPlugin> {
  /// Creates a [PluginRef].
  ///
  /// Set [required] to `false` for optional dependencies that the plugin
  /// can gracefully degrade without.
  PluginRef({this.required = true});

  /// Whether the registry must find a matching plugin.
  ///
  /// When `true` (default), `PluginRegistry.attachTo` throws [StateError]
  /// if no registered plugin matches type [T].
  final bool required;

  T? _resolved;

  /// The resolved plugin. Throws [StateError] if not yet resolved.
  T get plugin {
    final p = _resolved;
    if (p == null) {
      throw StateError(
        'PluginRef<$T> not resolved. '
        'Ensure the plugin is registered and attachTo has been called.',
      );
    }
    return p;
  }

  /// Whether this ref has been resolved to a concrete plugin.
  bool get isResolved => _resolved != null;

  /// Whether [candidate] is assignable to the target type [T].
  bool accepts(MontyPlugin candidate) => candidate is T;

  /// Binds this ref to [target]. Called by the registry during attachment.
  ///
  /// Throws [StateError] if already bound to a different plugin.
  @internal
  void bind(T target) {
    if (_resolved != null && _resolved != target) {
      throw StateError('PluginRef<$T> already bound.');
    }
    _resolved = target;
  }
}

/// Mixin for plugins that depend on other plugins in the same registry.
///
/// Declare [PluginRef] fields and return them from [dependencies].
/// The `PluginRegistry` resolves all refs before calling [onRegister],
/// so dependencies are available by the time your plugin initialises.
///
/// ```dart
/// class BudgetPlugin extends MontyPlugin with CompositePlugin {
///   final memoryRef = PluginRef<MemoryPlugin>();
///   final plannerRef = PluginRef<PlannerPlugin>(required: false);
///
///   @override
///   List<PluginRef<MontyPlugin>> get dependencies => [memoryRef, plannerRef];
///
///   @override
///   List<HostFunction> get functions => [ /* ... */ ];
/// }
/// ```
mixin CompositePlugin on MontyPlugin {
  /// Refs to sibling plugins this plugin depends on.
  ///
  /// Returned refs are resolved by the registry before [onRegister].
  List<PluginRef<MontyPlugin>> get dependencies;
}
