import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const _deepEq = DeepCollectionEquality();

/// A typed representation of a Python value crossing the Rust-Dart boundary.
///
/// Each subclass corresponds to a Python type. Use pattern matching:
/// ```dart
/// switch (result.value) {
///   case MontyInt(:final value): print('int: $value');
///   case MontyString(:final value): print('str: $value');
///   case MontyDate(:final year, :final month, :final day): ...
///   case MontyList(:final items): ...
///   case null: print('no value');
/// }
/// ```
sealed class MontyValue {
  const MontyValue();

  /// Deserializes a JSON value into the appropriate [MontyValue] subclass.
  ///
  /// Handles:
  /// - Scalars: null, bool, int, double, String
  /// - Collections: List (→ [MontyList]), Map without `__type` (→ [MontyDict])
  /// - Typed wrappers: Map with `__type` key dispatches to the appropriate type
  factory MontyValue.fromJson(Object? json) => switch (json) {
        null => const MontyNull(),
        bool b => MontyBool(b),
        int n => MontyInt(n),
        double d => MontyFloat(d),
        num n =>
          n == n.toInt() ? MontyInt(n.toInt()) : MontyFloat(n.toDouble()),
        'NaN' => const MontyFloat(double.nan),
        'Infinity' => const MontyFloat(double.infinity),
        '-Infinity' => const MontyFloat(double.negativeInfinity),
        String s => MontyString(s),
        List<dynamic> l => MontyList(l.map(MontyValue.fromJson).toList()),
        Map<String, dynamic> m => _parseMap(m),
        _ => MontyString(json.toString()),
      };

  static MontyValue _parseMap(Map<String, dynamic> map) {
    final type = map['__type'] as String?;
    if (type == null) {
      return MontyDict(
        map.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
      );
    }
    return switch (type) {
      'bytes' => MontyBytes._fromMap(map),
      'tuple' => MontyTuple._fromMap(map),
      'set' => MontySet._fromMap(map),
      'frozenset' => MontyFrozenSet._fromMap(map),
      'date' => MontyDate._fromMap(map),
      'datetime' => MontyDateTime._fromMap(map),
      'timedelta' => MontyTimeDelta._fromMap(map),
      'timezone' => MontyTimeZone._fromMap(map),
      'path' => MontyPath._fromMap(map),
      'namedtuple' => MontyNamedTuple._fromMap(map),
      'dataclass' => MontyDataclass._fromMap(map),
      _ => MontyDict(
          map.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
        ),
    };
  }

  /// Serializes this value back to JSON compatible with the Rust side.
  Object? toJson();

  /// Returns the underlying Dart value for easy migration.
  ///
  /// Scalars return their primitive (`int`, `double`, `String`, etc.).
  /// Collections recursively unwrap to `List<Object?>` / `Map<String, Object?>`.
  /// Typed wrappers return their `toJson()` map.
  Object? get dartValue;
}

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------

@immutable
final class MontyNull extends MontyValue {
  const MontyNull();

  @override
  Null toJson() => null;

  @override
  Null get dartValue => null;

  @override
  bool operator ==(Object other) => other is MontyNull;

  @override
  int get hashCode => null.hashCode;

  @override
  String toString() => 'MontyNull()';
}

@immutable
final class MontyBool extends MontyValue {
  const MontyBool(this.value);
  final bool value;

  @override
  bool toJson() => value;

  @override
  bool get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyBool && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyBool($value)';
}

@immutable
final class MontyInt extends MontyValue {
  const MontyInt(this.value);
  final int value;

  @override
  int toJson() => value;

  @override
  int get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyInt && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyInt($value)';
}

@immutable
final class MontyFloat extends MontyValue {
  const MontyFloat(this.value);
  final double value;

  @override
  Object toJson() {
    if (value.isNaN) return 'NaN';
    if (value == double.infinity) return 'Infinity';
    if (value == double.negativeInfinity) return '-Infinity';
    return value;
  }

  @override
  double get dartValue => value;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MontyFloat) return false;
    if (value.isNaN && other.value.isNaN) return true;
    return value == other.value;
  }

  @override
  int get hashCode => value.isNaN ? 0x7FF80000 : value.hashCode;

  @override
  String toString() => 'MontyFloat($value)';
}

@immutable
final class MontyString extends MontyValue {
  const MontyString(this.value);
  final String value;

  @override
  String toJson() => value;

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyString && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyString($value)';
}

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

@immutable
final class MontyBytes extends MontyValue {
  const MontyBytes(this.value);
  final List<int> value;

  factory MontyBytes._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];
    return MontyBytes(raw.cast<num>().map((n) => n.toInt()).toList());
  }

  @override
  Map<String, Object?> toJson() => {'__type': 'bytes', 'value': value};

  @override
  List<int> get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyBytes && _deepEq.equals(other.value, value));

  @override
  int get hashCode => _deepEq.hash(value);

  @override
  String toString() => 'MontyBytes(${value.length} bytes)';
}

@immutable
final class MontyList extends MontyValue {
  const MontyList(this.items);
  final List<MontyValue> items;

  @override
  List<Object?> toJson() => items.map((e) => e.toJson()).toList();

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyList && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontyList(${items.length} items)';
}

@immutable
final class MontyTuple extends MontyValue {
  const MontyTuple(this.items);
  final List<MontyValue> items;

  factory MontyTuple._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];
    return MontyTuple(raw.map(MontyValue.fromJson).toList());
  }

  @override
  Map<String, Object?> toJson() => {
        '__type': 'tuple',
        'value': items.map((e) => e.toJson()).toList(),
      };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTuple && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontyTuple(${items.length} items)';
}

@immutable
final class MontyDict extends MontyValue {
  const MontyDict(this.entries);
  final Map<String, MontyValue> entries;

  @override
  Map<String, Object?> toJson() =>
      entries.map((k, v) => MapEntry(k, v.toJson()));

  @override
  Map<String, Object?> get dartValue =>
      entries.map((k, v) => MapEntry(k, v.dartValue));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDict && _deepEq.equals(other.entries, entries));

  @override
  int get hashCode => _deepEq.hash(entries);

  @override
  String toString() => 'MontyDict(${entries.length} entries)';
}

@immutable
final class MontySet extends MontyValue {
  const MontySet(this.items);
  final List<MontyValue> items;

  factory MontySet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];
    return MontySet(raw.map(MontyValue.fromJson).toList());
  }

  @override
  Map<String, Object?> toJson() => {
        '__type': 'set',
        'value': items.map((e) => e.toJson()).toList(),
      };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontySet && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontySet(${items.length} items)';
}

@immutable
final class MontyFrozenSet extends MontyValue {
  const MontyFrozenSet(this.items);
  final List<MontyValue> items;

  factory MontyFrozenSet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];
    return MontyFrozenSet(raw.map(MontyValue.fromJson).toList());
  }

  @override
  Map<String, Object?> toJson() => {
        '__type': 'frozenset',
        'value': items.map((e) => e.toJson()).toList(),
      };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFrozenSet && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontyFrozenSet(${items.length} items)';
}

// ---------------------------------------------------------------------------
// DateTime types
// ---------------------------------------------------------------------------

@immutable
final class MontyDate extends MontyValue {
  const MontyDate({required this.year, required this.month, required this.day});
  final int year;
  final int month;
  final int day;

  factory MontyDate._fromMap(Map<String, dynamic> map) => MontyDate(
        year: (map['year'] as num).toInt(),
        month: (map['month'] as num).toInt(),
        day: (map['day'] as num).toInt(),
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'date',
        'year': year,
        'month': month,
        'day': day,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDate &&
          other.year == year &&
          other.month == month &&
          other.day == day);

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() =>
      'MontyDate($year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')})';
}

@immutable
final class MontyDateTime extends MontyValue {
  const MontyDateTime({
    required this.year,
    required this.month,
    required this.day,
    required this.hour,
    required this.minute,
    required this.second,
    this.microsecond = 0,
    this.offsetSeconds,
    this.timezoneName,
  });

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;
  final int microsecond;
  final int? offsetSeconds;
  final String? timezoneName;

  factory MontyDateTime._fromMap(Map<String, dynamic> map) => MontyDateTime(
        year: (map['year'] as num).toInt(),
        month: (map['month'] as num).toInt(),
        day: (map['day'] as num).toInt(),
        hour: (map['hour'] as num).toInt(),
        minute: (map['minute'] as num).toInt(),
        second: (map['second'] as num).toInt(),
        microsecond: (map['microsecond'] as num?)?.toInt() ?? 0,
        offsetSeconds: (map['offset_seconds'] as num?)?.toInt(),
        timezoneName: map['timezone_name'] as String?,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'datetime',
        'year': year,
        'month': month,
        'day': day,
        'hour': hour,
        'minute': minute,
        'second': second,
        'microsecond': microsecond,
        'offset_seconds': offsetSeconds,
        'timezone_name': timezoneName,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDateTime &&
          other.year == year &&
          other.month == month &&
          other.day == day &&
          other.hour == hour &&
          other.minute == minute &&
          other.second == second &&
          other.microsecond == microsecond &&
          other.offsetSeconds == offsetSeconds &&
          other.timezoneName == timezoneName);

  @override
  int get hashCode => Object.hash(
        year, month, day, hour, minute, second, microsecond,
        offsetSeconds, timezoneName,
      );

  @override
  String toString() => 'MontyDateTime($year-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}T'
      '${hour.toString().padLeft(2, '0')}:'
      '${minute.toString().padLeft(2, '0')}:'
      '${second.toString().padLeft(2, '0')})';
}

@immutable
final class MontyTimeDelta extends MontyValue {
  const MontyTimeDelta({
    required this.days,
    required this.seconds,
    this.microseconds = 0,
  });

  final int days;
  final int seconds;
  final int microseconds;

  factory MontyTimeDelta._fromMap(Map<String, dynamic> map) => MontyTimeDelta(
        days: (map['days'] as num).toInt(),
        seconds: (map['seconds'] as num).toInt(),
        microseconds: (map['microseconds'] as num?)?.toInt() ?? 0,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'timedelta',
        'days': days,
        'seconds': seconds,
        'microseconds': microseconds,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeDelta &&
          other.days == days &&
          other.seconds == seconds &&
          other.microseconds == microseconds);

  @override
  int get hashCode => Object.hash(days, seconds, microseconds);

  @override
  String toString() => 'MontyTimeDelta(days=$days, seconds=$seconds)';
}

@immutable
final class MontyTimeZone extends MontyValue {
  const MontyTimeZone({required this.offsetSeconds, this.name});
  final int offsetSeconds;
  final String? name;

  factory MontyTimeZone._fromMap(Map<String, dynamic> map) => MontyTimeZone(
        offsetSeconds: (map['offset_seconds'] as num).toInt(),
        name: map['name'] as String?,
      );

  @override
  Map<String, Object?> toJson() => {
        '__type': 'timezone',
        'offset_seconds': offsetSeconds,
        'name': name,
      };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTimeZone &&
          other.offsetSeconds == offsetSeconds &&
          other.name == name);

  @override
  int get hashCode => Object.hash(offsetSeconds, name);

  @override
  String toString() => 'MontyTimeZone(offset=$offsetSeconds, name=$name)';
}

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
