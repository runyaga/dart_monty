part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

/// Represents a Python `bytes` value.
@immutable
final class MontyBytes extends MontyValue {
  /// Creates a [MontyBytes] with the given byte [value].
  const MontyBytes(this.value);

  factory MontyBytes._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontyBytes(raw.cast<num>().map((n) => n.toInt()).toList());
  }

  /// The underlying list of byte values.
  final List<int> value;

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

/// Represents a Python `list` value.
@immutable
final class MontyList extends MontyValue {
  /// Creates a [MontyList] with the given [items].
  const MontyList(this.items);

  /// The list of [MontyValue] items.
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

/// Represents a Python `tuple` value.
@immutable
final class MontyTuple extends MontyValue {
  /// Creates a [MontyTuple] with the given [items].
  const MontyTuple(this.items);

  factory MontyTuple._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontyTuple(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the tuple.
  final List<MontyValue> items;

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

/// Represents a Python `dict` value.
@immutable
final class MontyDict extends MontyValue {
  /// Creates a [MontyDict] with the given [entries].
  const MontyDict(this.entries);

  /// The map of string keys to [MontyValue] values.
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

/// Represents a Python `set` value.
@immutable
final class MontySet extends MontyValue {
  /// Creates a [MontySet] with the given [items].
  const MontySet(this.items);

  factory MontySet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontySet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the set.
  final List<MontyValue> items;

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

/// Represents a Python `frozenset` value.
@immutable
final class MontyFrozenSet extends MontyValue {
  /// Creates a [MontyFrozenSet] with the given [items].
  const MontyFrozenSet(this.items);

  factory MontyFrozenSet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontyFrozenSet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the frozen set.
  final List<MontyValue> items;

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
