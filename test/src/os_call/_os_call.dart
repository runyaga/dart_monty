import 'package:dart_monty_core/dart_monty_core.dart';

/// An [OsHandler] seen through plain Dart values, so handler-level tests read
/// as they did before the handlers took [MontyValue]s.
typedef DartOsCall =
    Future<Object?> Function(
      String operation,
      List<Object?> args,
      Map<String, Object?>? kwargs,
    );

/// Wraps [handler]: each argument goes through [MontyValue.fromDart], and
/// the result comes back with scalars, lists and dicts lowered to Dart
/// values. Typed values (`MontyBytes`, `MontyPath`, `MontyFileHandle`,
/// dates) stay as they are.
DartOsCall dartCall(OsHandler handler) =>
    (operation, args, kwargs) async => lowerOsResult(
      await handler(
        operation,
        [for (final a in args) MontyValue.fromDart(a)],
        {
          for (final e in (kwargs ?? const <String, Object?>{}).entries)
            e.key: MontyValue.fromDart(e.value),
        },
      ),
    );

/// [value] with scalars, lists and string-keyed dicts lowered to Dart values.
Object? lowerOsResult(MontyValue value) => switch (value) {
  MontyNone() ||
  MontyBool() ||
  MontyInt() ||
  MontyFloat() ||
  MontyString() => value.dartValue,
  MontyList(:final items) when items.every((i) => i is MontyPath) =>
    items.cast<MontyPath>(),
  MontyList(:final items) => [for (final i in items) lowerOsResult(i)],
  MontyDict(:final pairs) when pairs.every((p) => p.$1 is MontyString) =>
    <String, Object?>{
      for (final (k, v) in pairs) (k as MontyString).value: lowerOsResult(v),
    },
  MontyDict(:final pairs) => {
    for (final (k, v) in pairs) k.dartValue: lowerOsResult(v),
  },
  _ => value,
};
