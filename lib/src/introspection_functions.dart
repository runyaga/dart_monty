import 'dart:convert';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Category name for introspection builtins.
const introspectionCategory = 'introspection';

/// Describes live host-function introspection.
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

/// Builds introspection against the bridge's live registry.
List<HostFunction> buildIntrospectionFunctions(MontyBridge bridge) {
  return [
    HostFunction(
      schema: helpSchema,
      handler: (args, _) async {
        final name = switch (args['name']) {
          MontyString(:final value) => value,
          _ => null,
        };
        final schemas = bridge.schemasByCategory;
        if (name == null) return MontyString(_handleListAll(schemas));

        return MontyString(_handleHelp(schemas, name));
      },
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
    if (schema.description != null) 'description': schema.description,
    'params': [for (final p in schema.params) _serializeParam(p)],
  };
}

/// Renders all live schema categories.
String _handleListAll(Map<String, List<HostFunctionSchema>> schemasByCategory) {
  final tools = <String, Object?>{};

  for (final entry in schemasByCategory.entries) {
    tools[entry.key] = [for (final s in entry.value) _serializeSchema(s)];
  }

  return jsonEncode({'tools': tools});
}

/// Renders a named schema or its ambiguous matches.
String _handleHelp(
  Map<String, List<HostFunctionSchema>> schemasByCategory,
  String name,
) {
  // 1. Exact match on fully-qualified name.
  for (final schemas in schemasByCategory.values) {
    for (final schema in schemas) {
      if (schema.name == name) {
        return jsonEncode(_serializeSchema(schema));
      }
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
