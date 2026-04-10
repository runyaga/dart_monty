import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';

/// Category name for introspection builtins.
const introspectionCategory = 'introspection';

/// Schema for the `list_functions` introspection function.
const listFunctionsSchema = HostFunctionSchema(
  name: 'list_functions',
  description: 'List all available host functions grouped by category.',
);

/// Schema for the `help` introspection function.
const helpSchema = HostFunctionSchema(
  name: 'help',
  description:
      'Show detailed information about a host function by name. '
      'Accepts both fully-qualified names (e.g. "storage_get") and bare names '
      '(e.g. "get"). If a bare name matches multiple functions, a '
      'disambiguation list is returned.',
  params: [
    HostParam(
      name: 'name',
      type: HostParamType.string,
      description: 'Fully-qualified or bare function name to look up.',
    ),
  ],
);

/// Builds the introspection host functions (`list_functions` and `help`).
///
/// Takes [schemasByCategory] from the registry so introspection can enumerate
/// all registered functions without a circular dependency on the registry.
List<HostFunction> buildIntrospectionFunctions(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
) {
  return [
    HostFunction(
      schema: listFunctionsSchema,
      handler: (args) async => _handleListFunctions(schemasByCategory),
      role: const InfraCall(),
    ),
    HostFunction(
      schema: helpSchema,
      handler: (args) async =>
          _handleHelp(schemasByCategory, args['name']! as String),
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

/// Handler for `list_functions`.
///
/// Returns JSON with all categories including introspection's own entries.
String _handleListFunctions(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
) {
  final tools = <String, Object?>{};

  for (final entry in schemasByCategory.entries) {
    tools[entry.key] = [for (final s in entry.value) _serializeSchema(s)];
  }

  // Include introspection's own schemas.
  tools[introspectionCategory] = [
    _serializeSchema(listFunctionsSchema),
    _serializeSchema(helpSchema),
  ];

  return jsonEncode({'tools': tools});
}

/// Handler for `help`.
///
/// Looks up [name] across all categories and the introspection schemas.
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
  for (final schema in [listFunctionsSchema, helpSchema]) {
    if (schema.name == name) {
      return jsonEncode(_serializeSchema(schema));
    }
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
