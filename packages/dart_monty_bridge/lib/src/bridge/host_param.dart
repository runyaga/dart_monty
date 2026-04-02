import 'package:dart_monty_bridge/src/bridge/host_param_type.dart';
import 'package:meta/meta.dart';

/// Describes a single parameter of a host function.
///
/// {@category Host Functions}
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
  final Object? defaultValue;

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
  ///
  /// If [jsonSchemaOverride] is set, returns it directly. Otherwise
  /// generates a schema from [type] and [description].
  Map<String, Object?> toJsonSchema() {
    if (jsonSchemaOverride != null) return jsonSchemaOverride!;

    // HostParamType.any accepts any value at runtime, so we emit an
    // unconstrained schema (no "type" key) rather than pinning to
    // "string" which would mislead LLMs into only sending strings.
    final schema = <String, Object?>{};
    if (type != HostParamType.any) {
      schema['type'] = type.jsonSchemaType;
    }
    if (description != null) schema['description'] = description;

    return schema;
  }

  /// Validates and optionally coerces [value].
  ///
  /// Returns the validated (possibly coerced) value.
  /// Throws [FormatException] if validation fails.
  Object? validate(Object? value) {
    if (value == null) {
      if (isRequired) {
        throw FormatException('Required parameter "$name" is null', value);
      }

      return defaultValue;
    }

    return switch (type) {
      HostParamType.string => _expectType<String>(value),
      HostParamType.integer => _coerceInt(value),
      HostParamType.number => _coerceNumber(value),
      HostParamType.boolean => _expectType<bool>(value),
      HostParamType.list => _expectType<List<Object?>>(value),
      HostParamType.map => _expectType<Map<String, Object?>>(value),
      HostParamType.any => value,
    };
  }

  T _expectType<T>(Object? value) {
    if (value is T) return value;
    throw FormatException(
      'Parameter "$name": expected $T, got ${value.runtimeType}',
      value,
    );
  }

  /// Accept int, num, or numeric string for integer params.
  int _coerceInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw FormatException(
      'Parameter "$name": expected int, got ${value.runtimeType}',
      value,
    );
  }

  /// Accept both int and double for number params.
  num _coerceNumber(Object? value) {
    if (value is num) return value;
    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw FormatException(
      'Parameter "$name": expected num, got ${value.runtimeType}',
      value,
    );
  }
}
