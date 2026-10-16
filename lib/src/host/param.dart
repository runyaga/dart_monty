import 'package:dart_monty/src/host/param_type.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Describes a single parameter of a host function.
@immutable
class HostParam {
  /// Creates a [HostParam].
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

  /// Whether the caller must supply a value.
  final bool isRequired;

  /// Human-readable description for JSON Schema export.
  final String? description;

  /// Default value when the argument is absent and not required.
  final MontyValue? defaultValue;

  /// Optional full JSON Schema override for this parameter.
  ///
  /// When set, [toJsonSchema] returns this map directly instead of
  /// generating from [type] and [description]. Use this for complex
  /// schemas (nested objects, enums, arrays with item types) that
  /// [HostParamType] cannot express.
  ///
  /// **Important:** The override controls only the schema advertised to
  /// external consumers (e.g. LLMs via MCP). Runtime validation in
  /// [validate] still uses [type]. Ensure the override is consistent
  /// with [type] to avoid mismatches where an LLM sends valid-per-schema
  /// arguments that fail runtime validation.
  final Map<String, Object?>? jsonSchemaOverride;

  /// Returns a JSON Schema property definition for this parameter.
  /// A map is advertised as a JSON object, but runtime dict keys may be any
  /// core-valid key. JSON Schema is not a reversible core value encoding.
  ///
  /// If [jsonSchemaOverride] is set, returns a copy of it. Otherwise
  /// generates a schema from [type] and [description].
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

  /// Validates a core value without conversion.
  /// Presence is independent of None.
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
