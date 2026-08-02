// ignore_for_file: avoid-unsafe-collection-methods
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Handler for `date.*` and `datetime.*` operations.
///
/// Accepts an injectable `clock` function for deterministic testing.
/// When no clock is provided, uses `DateTime.now`.
///
/// Register under both `date.` and `datetime.` prefixes:
/// ```dart
/// final time = timeHandler(clock: () => DateTime(2026, 1, 1));
/// composeOsHandlers({'date.': time, 'datetime.': time});
/// ```
OsCallHandler timeHandler({DateTime Function()? clock}) {
  final now = clock ?? DateTime.now;
  return (operation, args, kwargs) async {
    final t = now();
    return switch (operation) {
      // dart_monty_core 0.19 stopped honouring host-authored `__type` maps:
      // they arrive in Python as plain dicts, so `date.today().year` raised
      // AttributeError with no error at the boundary. Returning a MontyValue
      // subclass is the documented replacement (core CHANGELOG, 0.19.0
      // Breaking).
      'date.today' => MontyDate(year: t.year, month: t.month, day: t.day),
      // Constructed explicitly rather than handing `t` to MontyValue.fromDart:
      // that arm calls .toUtc() and leaves offsetSeconds/timezoneName null,
      // which would silently drop both fields this handler has always emitted.
      'datetime.now' => MontyDateTime(
        year: t.year,
        month: t.month,
        day: t.day,
        hour: t.hour,
        minute: t.minute,
        second: t.second,
        microsecond: t.microsecond,
        offsetSeconds: t.timeZoneOffset.inSeconds,
        timezoneName: t.timeZoneName,
      ),
      _ => throw UnsupportedError('Unsupported datetime operation: $operation'),
    };
  };
}

/// Handler for `os.*` environment operations using a provided map.
///
/// Prevents leaking the host's full environment into sandboxed Python code —
/// only the keys in [environment] are visible.
///
/// ```dart
/// envHandler({'APP_ENV': 'production', 'DEBUG': '0'});
/// ```
OsCallHandler envHandler(Map<String, String> environment) {
  return (operation, args, kwargs) async {
    return switch (operation) {
      'os.getenv' =>
        environment[osArgString(args.first)] ??
            (args.length > 1 ? args[1] : null),
      'os.environ' => Map<String, String>.unmodifiable(environment),
      _ => throw UnsupportedError('Unsupported env operation: $operation'),
    };
  };
}
