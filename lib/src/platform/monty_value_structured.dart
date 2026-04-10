part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Path
// ---------------------------------------------------------------------------

/// Represents a Python `pathlib.Path` value.
@immutable
final class MontyPath extends MontyValue {
  /// Creates a [MontyPath] with the given string [value].
  const MontyPath(this.value);

  factory MontyPath._fromMap(Map<String, dynamic> map) =>
      MontyPath(map['value'] as String? ?? '');

  /// The underlying path string.
  final String value;

  @override
  Map<String, Object?> toJson() => {'__type': 'path', 'value': value};

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyPath && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyPath($value)';
}

// ---------------------------------------------------------------------------
// Structured types
// ---------------------------------------------------------------------------

/// Represents a Python `collections.namedtuple` value.
@immutable
final class MontyNamedTuple extends MontyValue {
  /// Creates a [MontyNamedTuple].
  const MontyNamedTuple({
    required this.typeName,
    required this.fieldNames,
    required this.values,
  });

  factory MontyNamedTuple._fromMap(Map<String, dynamic> map) => MontyNamedTuple(
    typeName: map['type_name'] as String? ?? '',
    fieldNames:
        (map['field_names'] as List<dynamic>?)?.cast<String>().toList() ??
        const [],
    values:
        (map['values'] as List<dynamic>?)?.map(MontyValue.fromJson).toList() ??
        const [],
  );

  /// The name of the namedtuple type.
  final String typeName;

  /// The field names of the namedtuple.
  final List<String> fieldNames;

  /// The field values.
  final List<MontyValue> values;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'namedtuple',
    'type_name': typeName,
    'field_names': fieldNames,
    'values': values.map((e) => e.toJson()).toList(),
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyNamedTuple &&
          other.typeName == typeName &&
          _deepEq.equals(other.fieldNames, fieldNames) &&
          _deepEq.equals(other.values, values));

  @override
  int get hashCode =>
      Object.hash(typeName, _deepEq.hash(fieldNames), _deepEq.hash(values));

  @override
  String toString() =>
      'MontyNamedTuple($typeName, ${fieldNames.length} fields)';
}

/// Represents a Python `@dataclass` value.
@immutable
final class MontyDataclass extends MontyValue {
  /// Creates a [MontyDataclass].
  const MontyDataclass({
    required this.name,
    required this.typeId,
    required this.fieldNames,
    required this.attrs,
    this.frozen = false,
  });

  factory MontyDataclass._fromMap(Map<String, dynamic> map) {
    final rawAttrs = map['attrs'];
    final parsedAttrs = rawAttrs is Map<String, dynamic>
        ? rawAttrs.map((k, v) => MapEntry(k, MontyValue.fromJson(v)))
        : const <String, MontyValue>{};

    return MontyDataclass(
      name: map['name'] as String? ?? '',
      typeId: (map['type_id'] as num?)?.toInt() ?? 0,
      fieldNames:
          (map['field_names'] as List<dynamic>?)?.cast<String>().toList() ??
          const [],
      attrs: parsedAttrs,
      frozen: map['frozen'] as bool? ?? false,
    );
  }

  /// The dataclass name.
  final String name;

  /// The numeric type identifier.
  final int typeId;

  /// The field names of the dataclass.
  final List<String> fieldNames;

  /// The attribute values keyed by field name.
  final Map<String, MontyValue> attrs;

  /// Whether the dataclass is frozen (immutable).
  final bool frozen;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'dataclass',
    'name': name,
    'type_id': typeId,
    'field_names': fieldNames,
    'attrs': attrs.map((k, v) => MapEntry(k, v.toJson())),
    'frozen': frozen,
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDataclass &&
          other.name == name &&
          other.typeId == typeId &&
          _deepEq.equals(other.fieldNames, fieldNames) &&
          _deepEq.equals(other.attrs, attrs) &&
          other.frozen == frozen);

  @override
  int get hashCode => Object.hash(
    name,
    typeId,
    _deepEq.hash(fieldNames),
    _deepEq.hash(attrs),
    frozen,
  );

  @override
  String toString() => 'MontyDataclass($name, ${attrs.length} attrs)';
}
