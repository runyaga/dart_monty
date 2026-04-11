import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';

/// Handles `date.*` and `datetime.*` OS calls.
///
/// Accepts an injectable `clock` function for deterministic testing.
/// When no clock is provided, uses `DateTime.now`.
///
/// Register under both `'date.'` and `'datetime.'` prefixes in the router:
/// ```dart
/// final time = TimeOsCallHandler(clock: () => DateTime(2026, 1, 1));
/// RouterOsCallHandler({
///   'date.': time,
///   'datetime.': time,
/// });
/// ```
class TimeOsCallHandler extends OsCallHandler {
  /// Creates a handler with an optional frozen [clock].
  TimeOsCallHandler({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  @override
  Future<Object?> handle(MontyOsCall call) {
    final now = _clock();

    return Future.value(switch (call.operationName) {
      'date.today' => {
        '__type': 'date',
        'year': now.year,
        'month': now.month,
        'day': now.day,
      },
      'datetime.now' => {
        '__type': 'datetime',
        'year': now.year,
        'month': now.month,
        'day': now.day,
        'hour': now.hour,
        'minute': now.minute,
        'second': now.second,
        'microsecond': now.microsecond,
        'offset_seconds': now.timeZoneOffset.inSeconds,
        'timezone_name': now.timeZoneName,
      },
      final op => throw UnsupportedError('Unsupported datetime operation: $op'),
    });
  }
}
