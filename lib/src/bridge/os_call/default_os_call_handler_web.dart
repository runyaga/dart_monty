import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';

/// Creates a default OsCallHandler for web platforms.
///
/// Supports datetime operations (via Dart's DateTime which works on web).
/// Filesystem and environment operations throw PermissionError since
/// dart:io is not available in the browser.
OsCallHandler createDefaultOsCallHandler() {
  return (MontyOsCall call) => Future.value(_handleCall(call));
}

Object? _handleCall(MontyOsCall call) {
  switch (call.operationName) {
    case 'date.today':
      final now = DateTime.now();

      return {
        '__type': 'date',
        'year': now.year,
        'month': now.month,
        'day': now.day,
      };
    case 'datetime.now':
      final now = DateTime.now();

      return {
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
      };
    default:
      throw UnsupportedError(
        'PermissionError: ${call.operationName} not available on web',
      );
  }
}
