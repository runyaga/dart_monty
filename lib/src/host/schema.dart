import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Schema for a host function callable from Python.
///
/// Defines the function's name, description, and ordered parameters.
/// Handles mapping Monty's positional/keyword arguments to named parameters
/// and validates types before the handler runs.
@immutable
class HostFunctionSchema {
  /// Creates a [HostFunctionSchema].
  ///
  /// [description] is optional. Infrastructure functions (e.g. `help`) may
  /// omit it.
  const HostFunctionSchema({
    required this.name,
    this.description,
    this.params = const [],
  });

  /// Function name as registered with the Monty runtime.
  final String name;

  /// Human-readable description for tool export.
  ///
  /// `null` when no description has been provided. Omitted from JSON schema
  /// and system-prompt output when `null`.
  final String? description;

  /// Ordered parameter definitions.
  ///
  /// Positional args from Monty are mapped to params by insertion order.
  /// Keyword args overlay by name.
  final List<HostParam> params;

  /// Returns a JSON Schema object describing this function's input.
  ///
  /// Produces a schema compatible with MCP tool `inputSchema`:
  /// ```json
  /// {
  ///   "type": "object",
  ///   "properties": { ... },
  ///   "required": ["param1"]
  /// }
  /// ```
  Map<String, Object?> toJsonSchema() {
    final properties = <String, Object?>{};
    final required = <String>[];

    for (final param in params) {
      properties[param.name] = param.toJsonSchema();
      if (param.isRequired) required.add(param.name);
    }

    return {
      'type': 'object',
      'properties': properties,
      if (required.isNotEmpty) 'required': required,
    };
  }
}

/// Maps a call's positional [args] and keyword [kwargs], as
/// `MontyHostFunction.fn` receives them, to [schema]'s named parameters.
///
/// 1. Positional args are matched to `params` by order.
/// 2. Keyword args (`kwargs`) overlay by name.
/// 3. Each param is validated via [HostParam.validate].
///
/// Throws [FormatException] if required params are missing or types mismatch.
Map<String, MontyValue> mapAndValidate(
  HostFunctionSchema schema,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final HostFunctionSchema(:name, :params) = schema;
  final raw = <String, MontyValue>{};
  final positionalArgs = args;

  // Reject extra positional args.
  if (positionalArgs.length > params.length) {
    throw FormatException(
      '$name: expected at most ${params.length} positional argument(s), '
      'got ${positionalArgs.length}',
    );
  }

  // Positional args → named params by schema order
  for (var i = 0; i < params.length && i < positionalArgs.length; i++) {
    raw[params[i].name] = positionalArgs[i];
  }

  // Kwargs overlay — reject unknown keys.
  final paramNames = params.map((p) => p.name).toSet();
  for (final key in kwargs.keys) {
    if (!paramNames.contains(key)) {
      throw FormatException('$name: unknown keyword argument "$key"');
    }
  }
  for (final entry in kwargs.entries) {
    raw[entry.key] = entry.value;
  }

  // Validate all params
  final validated = <String, MontyValue>{};
  for (final param in params) {
    // `containsKey`, not a null check: `raw` holds only the arguments the
    // caller actually supplied, so this is the one place that can tell
    // "message omitted" from "message=None". HostParam.validate needs the
    // difference — see the comment there.
    validated[param.name] = param.validate(
      raw[param.name],
      isPresent: raw.containsKey(param.name),
    );
  }

  return validated;
}

/// Rejects an invalid configured default when its function is registered.
void validateDefaults(HostFunctionSchema schema) {
  for (final param in schema.params) {
    if (param.defaultValue case final value?) param.validate(value);
  }
}

/// Thrown by [mapAndValidateParity] when positional or keyword binding fails
/// with an upstream-compatible Python `TypeError`.
@internal
@immutable
final class ParityBindingException implements Exception {
  const ParityBindingException._(this.message);

  /// Upstream-compatible `TypeError` message (without `'TypeError: '` prefix).
  final String message;

  @override
  String toString() => message;
}

String _formatMissingNames(List<String> quoted) => switch (quoted.length) {
  1 => quoted.single,
  2 => '${quoted.first} and ${quoted[1]}',
  _ => '${quoted.sublist(0, quoted.length - 1).join(', ')}, and ${quoted.last}',
};

void _checkPositionalCount(String name, int expected, int given) {
  if (given <= expected) return;
  final expectedNoun = expected == 1 ? 'argument' : 'arguments';
  final givenVerb = given == 1 ? 'was' : 'were';
  throw ParityBindingException._(
    '$name() takes $expected positional $expectedNoun '
    'but $given $givenVerb given',
  );
}

void _checkKeywordArgs(
  String name,
  List<HostParam> params,
  Map<String, MontyValue> kwargs,
) {
  final paramNames = params.map((p) => p.name).toSet();
  for (final key in kwargs.keys) {
    if (!paramNames.contains(key)) {
      throw ParityBindingException._(
        "$name() got an unexpected keyword argument '$key'",
      );
    }
  }
}

void _checkMissingArgs(
  String name,
  List<HostParam> params,
  Map<String, MontyValue> raw,
) {
  final missing = <String>[
    for (final param in params)
      if (param.isRequired && !raw.containsKey(param.name)) "'${param.name}'",
  ];
  if (missing.isEmpty) return;
  final noun = missing.length == 1 ? 'argument' : 'arguments';
  final names = _formatMissingNames(missing);
  throw ParityBindingException._(
    '$name() missing ${missing.length} required positional $noun: $names',
  );
}

/// Parity-mode binder for `HostFunction.parity`.
///
/// Throws [ParityBindingException] with Monty 1.1.0 `TypeError` text for too
/// many positional arguments, unexpected keyword arguments, or missing required
/// arguments. Delegates value/type checks to [HostParam.validate], which
/// continues to throw [FormatException].
@internal
Map<String, MontyValue> mapAndValidateParity(
  HostFunctionSchema schema,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final HostFunctionSchema(:name, :params) = schema;
  _checkPositionalCount(name, params.length, args.length);

  final raw = <String, MontyValue>{
    for (var i = 0; i < params.length && i < args.length; i++)
      params[i].name: args[i],
  };

  _checkKeywordArgs(name, params, kwargs);
  raw.addAll(kwargs);
  _checkMissingArgs(name, params, raw);

  return {
    for (final param in params)
      param.name: param.validate(
        raw[param.name],
        isPresent: raw.containsKey(param.name),
      ),
  };
}
