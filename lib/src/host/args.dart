import 'package:dart_monty_core/dart_monty_core.dart';

/// Application-level primitive access for bundled handlers after validation.
extension HostArgs on Map<String, MontyValue> {
  /// The string payload for [key].
  String str(String key) => (this[key]! as MontyString).value;

  /// A bounded integer used for a handle or configuration count.
  int intArg(String key) => (this[key]! as MontyInt).value;

  /// An optional bounded integer; None means no override.
  int? intArgOrNull(String key) => switch (this[key]) {
    null || MontyNone() => null,
    final MontyInt value => value.value,
    _ => throw ArgumentError('Expected a bounded integer for $key'),
  };

  /// The list's core values, with no recursive lowering.
  List<MontyValue> listArg(String key) => (this[key]! as MontyList).items;
}
