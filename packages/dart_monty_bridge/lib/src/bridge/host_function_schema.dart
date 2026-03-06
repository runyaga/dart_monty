import 'package:dart_monty_bridge/src/bridge/host_param.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:meta/meta.dart';

/// Schema for a host function callable from Python.
///
/// Defines the function's name, description, and ordered parameters.
/// Handles mapping Monty's positional/keyword arguments to named parameters
/// and validates types before the handler runs.
@immutable
class HostFunctionSchema {
  /// Creates a [HostFunctionSchema].
  const HostFunctionSchema({
    required this.name,
    required this.description,
    this.params = const [],
  });

  /// Function name as registered with the Monty runtime.
  final String name;

  /// Human-readable description for tool export.
  final String description;

  /// Ordered parameter definitions.
  ///
  /// Positional args from Monty are mapped to params by insertion order.
  /// Keyword args overlay by name.
  final List<HostParam> params;

  /// Maps positional + keyword args from [pending] to a named parameter map.
  ///
  /// 1. Positional args are matched to [params] by order.
  /// 2. Keyword args (`kwargs`) overlay by name.
  /// 3. Each param is validated via [HostParam.validate].
  ///
  /// Throws [ArgumentError] if required params are missing or types mismatch.
  Map<String, Object?> mapAndValidate(MontyPending pending) {
    final raw = <String, Object?>{};

    // Positional args → named params by schema order
    for (var i = 0; i < params.length && i < pending.arguments.length; i++) {
      raw[params[i].name] = pending.arguments[i];
    }

    // Kwargs overlay
    final kwargs = pending.kwargs;
    if (kwargs != null) {
      for (final entry in kwargs.entries) {
        raw[entry.key] = entry.value;
      }
    }

    // Validate all params
    final validated = <String, Object?>{};
    for (final param in params) {
      validated[param.name] = param.validate(raw[param.name]);
    }

    return validated;
  }
}
