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

  /// Returns entries if this is a [MontyDict] whose keys are ALL strings,
  /// otherwise `null`.
  ///
  /// The string-key requirement is not new. Before `dart_monty_core` merged
  /// `MontyPairsDict` into `MontyDict`, a dict with any non-string key was a
  /// different Dart type, so this accessor — which only ever matched
  /// `MontyDict` — already answered `null` for it. Keeping the signature and
  /// the `null` keeps that contract through the merge, rather than widening a
  /// convenience accessor and making every caller handle `MontyValue` keys.
  ///
  /// Reach for `MontyDict.entries` directly when the general keyspace matters.
  Map<String, MontyValue>? asMap() => switch (this) {
    MontyDict(:final entries) => _asStringKeyed(entries),
    _ => null,
  };

  static Map<String, MontyValue>? _asStringKeyed(
    Map<String, MontyValue> entries,
  ) {
    // Note: MontyDict is already string-keyed in dart_monty_core ≥0.19.
    // This helper remains so the public contract of `asMap()` stays the same.
    return Map.unmodifiable(entries);
  }

  /// Returns raw bytes if this is [MontyBytes], otherwise `null`.
  List<int>? asBytes() => switch (this) {
    MontyBytes(:final value) => value,
    _ => null,
  };

  /// Whether this is [MontyNone] (Python `None`).
  bool get isNone => this is MontyNone;
}
