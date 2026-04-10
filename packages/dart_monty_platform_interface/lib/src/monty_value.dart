import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

part 'monty_value_scalars.dart';
part 'monty_value_collections.dart';
part 'monty_value_datetime.dart';
part 'monty_value_structured.dart';

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
