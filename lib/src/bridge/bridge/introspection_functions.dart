import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';

/// Category name for introspection builtins.
const introspectionCategory = 'introspection';

/// Schema for the `help` introspection function.
///
/// When called with no arguments, lists all available host functions grouped
/// by category. When called with a name, shows detailed information about
/// that function.
///
/// ```monty
/// help()                  # list all available functions
/// help("csv_parse")       # detail on a specific function
/// help("parse")           # bare name — disambiguates if needed
/// ```
const helpSchema = HostFunctionSchema(
  name: 'help',
  description:
      'Show detailed information about a host function by name, or list all '
      'available functions when called with no arguments. '
      'Accepts both fully-qualified names (e.g. "storage_get") and bare names '
      '(e.g. "get"). If a bare name matches multiple functions, a '
      'disambiguation list is returned.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      isRequired: false,
      description:
          'Fully-qualified or bare function name to look up. '
          'Omit to list all available functions.',
    ),
  ],
);

/// Builds the introspection host function (`help`).
///
/// Takes [schemasByCategory] from the registry so introspection can enumerate
/// all registered functions without a circular dependency on the registry.
List<HostFunction> buildIntrospectionFunctions(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
) {
  return [
    HostFunction(
      schema: helpSchema,
      handler: (args) async {
        final name = args['name'] as String?;
        if (name == null) return _handleListAll(schemasByCategory);

        return _handleHelp(schemasByCategory, name);
      },
      role: const InfraCall(),
    ),
  ];
}

/// Serializes a single [HostParam] to a JSON-compatible map.
Map<String, Object?> _serializeParam(HostParam param) {
  return {
    'name': param.name,
    'type': param.type.jsonSchemaType,
    'required': param.isRequired,
    if (param.description != null) 'description': param.description,
  };
}

/// Serializes a [HostFunctionSchema] to a summary map.
Map<String, Object?> _serializeSchema(HostFunctionSchema schema) {
  return {
    'name': schema.name,
    'description': schema.description,
    'params': [for (final p in schema.params) _serializeParam(p)],
  };
}

/// Handler for `help()` with no arguments.
///
/// Returns JSON with all categories including introspection's own entry.
String _handleListAll(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
) {
  final tools = <String, Object?>{};

  for (final entry in schemasByCategory.entries) {
    tools[entry.key] = [for (final s in entry.value) _serializeSchema(s)];
  }

  // Include introspection's own schema.
  tools[introspectionCategory] = [_serializeSchema(helpSchema)];

  return jsonEncode({'tools': tools});
}

/// Handler for `help(name)`.
///
/// Looks up [name] across all categories and the introspection schema.
/// Supports both fully-qualified names (`storage_get`) and bare names (`get`).
/// When a bare name matches exactly one function, returns its detail.
/// When multiple functions share the same bare name, returns a disambiguation
/// list.
String _handleHelp(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
  String name,
) {
  // 1. Exact match on fully-qualified name (backwards compatible).
  for (final schemas in schemasByCategory.values) {
    for (final schema in schemas) {
      if (schema.name == name) {
        return jsonEncode(_serializeSchema(schema));
      }
    }
  }
  if (helpSchema.name == name) {
    return jsonEncode(_serializeSchema(helpSchema));
  }

  // 2. Bare-name fuzzy match: strip namespace prefix and compare suffix.
  final bareMatches = <HostFunctionSchema>[];
  for (final entry in schemasByCategory.entries) {
    final prefix = '${entry.key}_';
    for (final schema in entry.value) {
      if (schema.name.startsWith(prefix) &&
          schema.name.substring(prefix.length) == name) {
        bareMatches.add(schema);
      }
    }
  }

  if (bareMatches.length == 1) {
    return jsonEncode(_serializeSchema(bareMatches.first));
  }
  if (bareMatches.length > 1) {
    final candidates = bareMatches.map((s) => s.name).toList()..sort();

    return jsonEncode({
      'error': 'ambiguous',
      'message':
          'Multiple functions match "$name". '
          'Use the fully-qualified name.',
      'candidates': candidates,
    });
  }

  return 'Unknown function: $name';
}
