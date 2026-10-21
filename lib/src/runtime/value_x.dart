// Internal and used by tests only: not exported (REQ values-and-inputs-10).
// ignore_for_file: unused-files
import 'package:dart_monty_core/dart_monty_core.dart';

/// Reads matching Dart payloads from core values without throwing.
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

  /// Returns sequence or set items when the receiver contains them.
  List<MontyValue>? asList() => switch (this) {
    MontyList(:final items) => items,
    MontyTuple(:final items) => items,
    MontySet(:final items) => items,
    MontyFrozenSet(:final items) => items,
    _ => null,
  };

  /// Returns string-keyed dictionary entries or null for any non-string key.
  Map<String, MontyValue>? asMap() {
    if (this case MontyDict(:final pairs)) {
      final map = <String, MontyValue>{};
      for (final (key, value) in pairs) {
        if (key is! MontyString) return null;
        map[key.value] = value;
      }

      return map;
    }

    return null;
  }

  /// Returns raw bytes if this is [MontyBytes], otherwise `null`.
  List<int>? asBytes() => switch (this) {
    MontyBytes(:final value) => value,
    _ => null,
  };

  /// Whether this is [MontyNone] (Python `None`).
  bool get isNone => this is MontyNone;
}
