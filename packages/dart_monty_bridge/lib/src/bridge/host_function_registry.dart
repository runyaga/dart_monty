import 'package:dart_monty_bridge/src/bridge/host_function.dart';
import 'package:dart_monty_bridge/src/bridge/host_function_schema.dart';
import 'package:dart_monty_bridge/src/bridge/introspection_functions.dart';
import 'package:dart_monty_bridge/src/bridge/monty_bridge.dart';

/// Groups [HostFunction]s by category and registers them (plus introspection
/// builtins) onto a [MontyBridge].
class HostFunctionRegistry {
  final Map<String, List<HostFunction>> _categories = {};

  /// Adds a named category of host functions.
  ///
  /// Throws [ArgumentError] if [name] is empty or already registered.
  void addCategory(String name, List<HostFunction> functions) {
    if (name.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'Category name must not be empty',
      );
    }
    if (_categories.containsKey(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'Category "$name" is already registered',
      );
    }
    _categories[name] = List.unmodifiable(functions);
  }

  /// Flat list of all registered functions across all categories.
  List<HostFunction> get allFunctions => [
    for (final fns in _categories.values) ...fns,
  ];

  /// Schemas grouped by category name — used by introspection functions.
  Map<String, List<HostFunctionSchema>> get schemasByCategory => {
    for (final entry in _categories.entries)
      entry.key: [for (final fn in entry.value) fn.schema],
  };

  /// Registers all category functions plus introspection builtins onto
  /// [bridge].
  void registerAllOnto(MontyBridge bridge) {
    allFunctions.forEach(bridge.register);
    buildIntrospectionFunctions(schemasByCategory).forEach(bridge.register);
  }
}
