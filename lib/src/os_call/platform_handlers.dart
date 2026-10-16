// ignore_for_file: avoid-unsafe-collection-methods
import 'package:dart_monty/src/os_call/lowered_os_handler.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show OsCallNotHandledException;

/// Handler for `os.*` environment operations using a provided map.
///
/// Prevents leaking the host's full environment into sandboxed Python code —
/// only the keys in [environment] are visible.
///
/// ```dart
/// envHandler({'APP_ENV': 'production', 'DEBUG': '0'});
/// ```
OsHandler envHandler(Map<String, String> environment) {
  return loweredOsHandler((operation, args, kwargs) {
    return switch (operation) {
      'os.getenv' =>
        environment[osArgString(args.first)] ??
            (args.length > 1 ? args[1] : null),
      'os.environ' => Map<String, String>.unmodifiable(environment),
      // Any other `os.*` call is not this handler's: decline it, so the worker
      // answers with its own default.
      _ => throw const OsCallNotHandledException(),
    };
  });
}
