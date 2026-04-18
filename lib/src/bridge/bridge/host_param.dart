import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/param_render_hint.dart';
import 'package:meta/meta.dart';

/// Describes a single parameter of a host function.
@immutable
class HostParam {
  /// Creates a [HostParam].
  ///
  /// [renderAs] and [renderHintFrom] are mutually exclusive. When
  /// neither is supplied the value renders as [ParamRenderHint.plain].
  const HostParam({
    required this.name,
    required this.type,
    this.isRequired = true,
    this.description,
    this.defaultValue,
    this.jsonSchemaOverride,
    this.renderAs,
    this.renderHintFrom,
  }) : assert(
         renderAs == null || renderHintFrom == null,
         'HostParam: renderAs and renderHintFrom are mutually exclusive.',
       );

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

  /// Advisory hint for how the value should be rendered in activity-log
  /// tiles and other developer-facing surfaces.
  ///
  /// Use this when the render style is fixed at schema time — e.g.
  /// `sandbox_spawn.code` is always Python.
  final ParamRenderHint? renderAs;

  /// Name of a sibling parameter whose runtime value determines the
  /// render hint.
  ///
  /// Use this for polymorphic tools where the hint depends on another
  /// arg — e.g. `execute_script(language="python", script="...")` sets
  /// `renderHintFrom: 'language'` on `script`. Consumers resolve the
  /// sibling's string value via `ParamRenderHint.values.byName` and fall
  /// back to [ParamRenderHint.plain] if the value is unrecognized.
  final String? renderHintFrom;

  /// Returns a JSON Schema property definition for this parameter.
  ///
  /// If [jsonSchemaOverride] is set, returns it as-is. Otherwise
  /// generates a schema from [type] and [description]. In both cases
  /// [renderAs] and [renderHintFrom] are appended as `x-render-as` and
  /// `x-render-hint-from` extension keys so downstream consumers
  /// (activity-log UIs, MCP clients that want to fence code blocks) can
  /// read the hint without special-casing the override path.
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
    if (renderAs != null) schema['x-render-as'] = renderAs!.name;
    if (renderHintFrom != null) schema['x-render-hint-from'] = renderHintFrom;

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

  /// Accepts only Dart [int] for integer params.
  ///
  /// Floats (even whole-number floats like 1.0) and strings are rejected —
  /// Monty maps Python `int` to Dart `int` directly. Accepting floats would
  /// silently truncate (1.5 → 1), masking type errors at the Python call site.
  int _coerceInt(Object? value) {
    if (value is int) return value;
    throw FormatException(
      'Parameter "$name": expected int, got ${value.runtimeType}',
      value,
    );
  }

  /// Accepts any Dart [num] (int or double) for number params.
  ///
  /// Strings are not coerced — Monty maps Python numeric types to Dart [num]
  /// directly. A string argument indicates a Python-side type error.
  num _coerceNumber(Object? value) {
    if (value is num) return value;
    throw FormatException(
      'Parameter "$name": expected num, got ${value.runtimeType}',
      value,
    );
  }
}
