import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Describes a single parameter of a host function.
@immutable
class HostParam {
  /// Declares one host-function parameter and its validation policy.
  const HostParam({
    required this.name,
    required this.type,
    this.isRequired = true,
    this.description,
    this.defaultValue,
    this.jsonSchemaOverride,
  });

  /// Parameter name (used as the key in the validated args map).
  final String name;

  /// Expected type.
  final HostParamType type;

  /// Whether the caller must supply a value. Defaults to true.
  final bool isRequired;

  /// Human-readable description for JSON Schema export.
  final String? description;

  /// Default value when the argument is absent and not required. Defaults to
  /// null, which supplies [MontyNone].
  final MontyValue? defaultValue;

  /// Overrides the advertised schema without changing runtime validation.
  final Map<String, Object?>? jsonSchemaOverride;

  /// Builds the advertised JSON Schema property for this parameter.
  Map<String, Object?> toJsonSchema() {
    final schema = jsonSchemaOverride != null
        ? <String, Object?>{...jsonSchemaOverride!}
        : <String, Object?>{};
    if (jsonSchemaOverride == null) {
      // HostParamType.any accepts any value at runtime, so we emit an
      // unconstrained schema (no "type" key) rather than pinning to
      // "string" which would mislead LLMs into only sending strings.
      if (type != HostParamType.any) {
        schema['type'] = type.jsonSchemaType;
      }
      if (description != null) schema['description'] = description;
    }

    return schema;
  }

  /// Validates a supplied value without conversion and supplies [defaultValue]
  /// or [MontyNone] for an omitted optional value.
  MontyValue validate(MontyValue? value, {bool isPresent = true}) {
    if (!isPresent) {
      if (isRequired) {
        throw FormatException('Required parameter "$name" is missing');
      }

      return defaultValue ?? const MontyNone();
    }
    if (value == null) {
      throw ArgumentError.value(
        value,
        name,
        'Present arguments must be MontyValue',
      );
    }
    if (value is MontyNone && (!isRequired || type == HostParamType.any)) {
      return value;
    }
    if (value is MontyNone) {
      throw FormatException('Required parameter "$name" is null');
    }
    final accepted = switch (type) {
      HostParamType.string => value is MontyString,
      HostParamType.integer => value is MontyInt || value is MontyBigInt,
      HostParamType.number =>
        value is MontyInt || value is MontyBigInt || value is MontyFloat,
      HostParamType.boolean => value is MontyBool,
      HostParamType.list => value is MontyList,
      HostParamType.map => value is MontyDict,
      HostParamType.any => true,
    };
    if (!accepted) {
      throw FormatException(
        'Parameter "$name": expected ${type.name}, got ${value.runtimeType}',
      );
    }

    return value;
  }
}
