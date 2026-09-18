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
      'datetime.now' => _datetimeNow(t, _requestedZone(args)),
      _ => throw UnsupportedError('Unsupported datetime operation: $operation'),
    };
  };
}

/// The timezone `datetime.now(tz)` asked for, or `null` for `datetime.now()`.
///
/// monty passes the requested zone positionally: `DateTimeNow` projects it into
/// `args[0]`, `None` when the call was naive. Arguments reach a handler already
/// lowered to `dartValue`, so a zone arrives as the wire map
/// `{'__type': 'timezone', …}`; [MontyValue.fromJson] turns that back into the
/// typed value rather than making this function key into a raw map.
MontyTimeZone? _requestedZone(List<Object?> args) {
  if (args.isEmpty || args.first == null) return null;
  final decoded = MontyValue.fromJson(args.first);
  if (decoded is MontyTimeZone) return decoded;
  if (decoded is MontyNone) return null;
  // Loudly, not silently: monty only ever sends None or a timezone here, so
  // anything else means the contract changed and guessing would hide it.
  throw ArgumentError.value(
    args.first,
    'args[0]',
    'datetime.now expects a timezone or None, got ${decoded.runtimeType}',
  );
}

/// Answers `datetime.now(tz)` the way monty specifies.
///
/// `tz == null` is **naive**: local wall-clock, and no offset or zone name.
/// Returning an aware value here diverges from CPython and from monty's own
/// contract ("`None` for a naive result", `OsFunctionCall::DateTimeNow`).
///
/// `tz != null` is **aware**: the same instant expressed in the requested zone,
/// carrying its offset and name — mirroring upstream's reference embedder
/// (`dispatch_datetime_now`, monty `crates/monty-datatest/src/main.rs`).
///
/// Built explicitly rather than via [MontyValue.fromDart], whose `DateTime` arm
/// calls `.toUtc()` and leaves offset and name null — correct for neither case.
MontyDateTime _datetimeNow(DateTime t, MontyTimeZone? tz) {
  if (tz == null) {
    return MontyDateTime(
      year: t.year,
      month: t.month,
      day: t.day,
      hour: t.hour,
      minute: t.minute,
      second: t.second,
      microsecond: t.microsecond,
    );
  }
  // Shift the instant, do not relabel the wall clock: an offset applied to UTC
  // is what makes `datetime.now(timezone.utc)` the same moment as `now()`.
  final shifted = t.toUtc().add(Duration(seconds: tz.offsetSeconds));
  return MontyDateTime(
    year: shifted.year,
    month: shifted.month,
    day: shifted.day,
    hour: shifted.hour,
    minute: shifted.minute,
    second: shifted.second,
    microsecond: shifted.microsecond,
    offsetSeconds: tz.offsetSeconds,
    timezoneName: tz.name,
  );
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
