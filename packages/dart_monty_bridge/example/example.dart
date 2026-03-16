// ignore_for_file: avoid_print, document_ignores

import 'package:dart_monty_bridge/dart_monty_bridge.dart';

/// A plugin that provides calculator host functions to Python scripts.
///
/// Demonstrates the core bridge concepts:
/// - Extending [MontyPlugin] with a namespace
/// - Defining [HostFunction]s with typed parameter schemas
/// - Async handlers that receive validated arguments
class CalculatorPlugin extends MontyPlugin {
  @override
  String get namespace => 'calc';

  @override
  String? get systemPromptContext =>
      'The calc plugin provides basic arithmetic operations.';

  @override
  List<HostFunction> get functions => [
    const HostFunction(
      schema: HostFunctionSchema(
        name: 'calc_add',
        description: 'Adds two numbers and returns the result.',
        params: [
          HostParam(
            name: 'a',
            type: HostParamType.number,
            description: 'First operand',
          ),
          HostParam(
            name: 'b',
            type: HostParamType.number,
            description: 'Second operand',
          ),
        ],
      ),
      handler: _add,
    ),
    const HostFunction(
      schema: HostFunctionSchema(
        name: 'calc_factorial',
        description: 'Computes the factorial of a non-negative integer.',
        params: [
          HostParam(
            name: 'n',
            type: HostParamType.integer,
            description: 'Non-negative integer',
          ),
        ],
      ),
      handler: _factorial,
    ),
  ];
}

Future<Object?> _add(Map<String, Object?> args) async {
  final a = args['a']! as num;
  final b = args['b']! as num;
  return a + b;
}

Future<Object?> _factorial(Map<String, Object?> args) async {
  final n = args['n']! as int;
  if (n < 0) throw ArgumentError.value(n, 'n', 'must be >= 0');
  var result = 1;
  for (var i = 2; i <= n; i++) {
    result *= i;
  }
  return result;
}

void main() {
  // Create a registry and register plugins.
  final registry = PluginRegistry()..register(CalculatorPlugin());

  // Generate a system prompt describing all available host functions.
  // This is typically sent to an LLM so it knows which tools it can call.
  final prompt = registry.generateSystemPrompt();
  print('=== System Prompt ===\n$prompt');

  // Inspect registered functions and their JSON schemas.
  print('\n=== Registered Functions ===');
  for (final plugin in registry.plugins) {
    for (final fn in plugin.functions) {
      print('${fn.schema.name}: ${fn.schema.toJsonSchema()}');
    }
  }
}
