part of 'monty_value.dart';

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
