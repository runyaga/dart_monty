part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Path
// ---------------------------------------------------------------------------

@immutable
final class MontyPath extends MontyValue {
  const MontyPath(this.value);
  final String value;

  factory MontyPath._fromMap(Map<String, dynamic> map) =>
      MontyPath(map['value'] as String? ?? '');

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

@immutable
final class MontyNamedTuple extends MontyValue {
  const MontyNamedTuple({
    required this.typeName,
    required this.fieldNames,
    required this.values,
  });

  final String typeName;
  final List<String> fieldNames;
  final List<MontyValue> values;

  factory MontyNamedTuple._fromMap(Map<String, dynamic> map) => MontyNamedTuple(
        typeName: map['type_name'] as String? ?? '',
        fieldNames: (map['field_names'] as List<dynamic>?)
                ?.cast<String>()
                .toList() ??
            const [],
        values: (map['values'] as List<dynamic>?)
                ?.map(MontyValue.fromJson)
                .toList() ??
            const [],
      );

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
  String toString() => 'MontyNamedTuple($typeName, ${fieldNames.length} fields)';
}

@immutable
final class MontyDataclass extends MontyValue {
  const MontyDataclass({
    required this.name,
    required this.typeId,
    required this.fieldNames,
    required this.attrs,
    this.frozen = false,
  });

  final String name;
  final int typeId;
  final List<String> fieldNames;
  final Map<String, MontyValue> attrs;
  final bool frozen;

  factory MontyDataclass._fromMap(Map<String, dynamic> map) {
    final rawAttrs = map['attrs'];
    final Map<String, MontyValue> parsedAttrs;
    if (rawAttrs is Map<String, dynamic>) {
      parsedAttrs =
          rawAttrs.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));
    } else {
      parsedAttrs = const {};
    }

    return MontyDataclass(
      name: map['name'] as String? ?? '',
      typeId: (map['type_id'] as num?)?.toInt() ?? 0,
      fieldNames: (map['field_names'] as List<dynamic>?)
              ?.cast<String>()
              .toList() ??
          const [],
      attrs: parsedAttrs,
      frozen: map['frozen'] as bool? ?? false,
    );
  }

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
