import 'package:dart_monty_core/dart_monty_core.dart';

/// Typed accessors on [MontyValue] — avoid `.dartValue` casts at call sites.
///
/// Each method returns the typed Dart value when the receiver is the matching
/// subtype, and `null` for every other subtype (including [MontyNone]).
///
/// ```dart
/// final v = result.value;
/// final s = v?.asString();          // String? — null if not a MontyString
/// final n = v?.asInt() ?? 0;        // int, defaulting to 0
/// final items = v?.asList() ?? [];  // List<MontyValue>
/// ```
extension MontyValueX on MontyValue {
  /// Returns the [String] value if this is [MontyString], otherwise `null`.
  String? asString() => switch (this) {
    MontyString(:final value) => value,
    _ => null,
  };

  /// Returns the [int] value if this is [MontyInt], otherwise `null`.
  int? asInt() => switch (this) {
    MontyInt(:final value) => value,
    _ => null,
  };

  /// Returns the [double] value if this is [MontyFloat], otherwise `null`.
  double? asDouble() => switch (this) {
    MontyFloat(:final value) => value,
    _ => null,
  };

  /// Returns the [bool] value if this is [MontyBool], otherwise `null`.
  bool? asBool() => switch (this) {
    MontyBool(:final value) => value,
    _ => null,
  };

  /// Returns items if this is [MontyList], [MontyTuple], [MontySet], or
  /// [MontyFrozenSet], otherwise `null`.
  List<MontyValue>? asList() => switch (this) {
    MontyList(:final items) => items,
    MontyTuple(:final items) => items,
    MontySet(:final items) => items,
    MontyFrozenSet(:final items) => items,
    _ => null,
  };

  /// Returns entries if this is [MontyDict], otherwise `null`.
  Map<String, MontyValue>? asMap() => switch (this) {
    MontyDict(:final entries) => entries,
    _ => null,
  };

  /// Returns raw bytes if this is [MontyBytes], otherwise `null`.
  List<int>? asBytes() => switch (this) {
    MontyBytes(:final value) => value,
    _ => null,
  };

  /// Whether this is [MontyNone] (Python `None`).
  bool get isNone => this is MontyNone;
}
