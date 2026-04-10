part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Scalars
// ---------------------------------------------------------------------------

/// Represents a Python `None` value.
@immutable
final class MontyNull extends MontyValue {
  /// Creates a [MontyNull].
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

/// Represents a Python `bool` value.
@immutable
final class MontyBool extends MontyValue {
  /// Creates a [MontyBool] with the given [value].
  // Value-type wrapper — single positional field is the intended API.
  // ignore: avoid_positional_boolean_parameters
  const MontyBool(this.value);

  /// The underlying boolean value.
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

/// Represents a Python `int` value.
@immutable
final class MontyInt extends MontyValue {
  /// Creates a [MontyInt] with the given [value].
  const MontyInt(this.value);

  /// The underlying integer value.
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

/// Represents a Python `float` value (including NaN and infinities).
@immutable
final class MontyFloat extends MontyValue {
  /// Creates a [MontyFloat] with the given [value].
  const MontyFloat(this.value);

  /// The underlying double value.
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

/// Represents a Python `str` value.
@immutable
final class MontyString extends MontyValue {
  /// Creates a [MontyString] with the given [value].
  const MontyString(this.value);

  /// The underlying string value.
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
