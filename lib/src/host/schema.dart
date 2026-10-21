import 'package:dart_monty/src/host/param.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Describes and validates a Python-callable host function.
@immutable
class HostFunctionSchema {
  /// Declares a host function's name and ordered parameters.
  const HostFunctionSchema({
    required this.name,
    this.description,
    this.params = const [],
  });

  /// Function name as registered with the Monty runtime.
  final String name;

  /// Supplies optional prose for tool export.
  final String? description;

  /// Defines positional binding order and keyword names.
  final List<HostParam> params;

  /// Builds an MCP-compatible JSON input schema.
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

/// Binds positional arguments in declaration order, overlays keywords, and
/// rejects an unknown, missing, or mistyped argument before a handler runs.
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

  // Keyword arguments overlay positional ones. Reject unknown keys.
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
    // difference. See the comment there.
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

/// Carries an upstream-compatible Python binding failure.
@internal
@immutable
final class ParityBindingException implements Exception {
  const ParityBindingException._(this.message);

  /// Provides an upstream-compatible `TypeError` message without its prefix.
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
  Map<String, MontyValue> raw,
  Map<String, MontyValue> kwargs,
) {
  final paramNames = params.map((p) => p.name).toSet();
  for (final key in kwargs.keys) {
    if (!paramNames.contains(key)) {
      throw ParityBindingException._(
        "$name() got an unexpected keyword argument '$key'",
      );
    }
    if (raw.containsKey(key)) {
      throw ParityBindingException._(
        "$name() got multiple values for argument '$key'",
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

/// Binds arguments with upstream-compatible Python failure messages.
@internal
Map<String, MontyValue> mapAndValidateParity(
  HostFunctionSchema schema,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) {
  final HostFunctionSchema(:name, :params) = schema;
  final raw = <String, MontyValue>{
    for (var i = 0; i < params.length && i < args.length; i++)
      params[i].name: args[i],
  };

  _checkKeywordArgs(name, params, raw, kwargs);
  _checkPositionalCount(name, params.length, args.length);
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
