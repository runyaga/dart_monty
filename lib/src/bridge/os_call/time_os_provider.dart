import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Handles `date.*` and `datetime.*` OS calls.
///
/// Accepts an injectable `clock` function for deterministic testing.
/// When no clock is provided, uses `DateTime.now`.
///
/// Register under both `'date.'` and `'datetime.'` prefixes:
/// ```dart
/// final time = TimeOsProvider(clock: () => DateTime(2026, 1, 1));
/// OsProvider.compose({
///   'date.': time,
///   'datetime.': time,
/// });
/// ```
class TimeOsProvider extends OsProvider {
  /// Creates a provider with an optional frozen [clock].
  TimeOsProvider({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      super.base();

  final DateTime Function() _clock;

  @override
  Future<Object?> resolve(MontyOsCall call) {
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
