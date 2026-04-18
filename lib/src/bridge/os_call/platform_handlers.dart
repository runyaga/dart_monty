// ignore_for_file: avoid-unsafe-collection-methods
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'package:dart_monty/src/bridge/os_call/os_handlers.dart';

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
      'date.today' => {
        '__type': 'date',
        'year': t.year,
        'month': t.month,
        'day': t.day,
      },
      'datetime.now' => {
        '__type': 'datetime',
        'year': t.year,
        'month': t.month,
        'day': t.day,
        'hour': t.hour,
        'minute': t.minute,
        'second': t.second,
        'microsecond': t.microsecond,
        'offset_seconds': t.timeZoneOffset.inSeconds,
        'timezone_name': t.timeZoneName,
      },
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
