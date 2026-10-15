import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyValue, OsHandler;

/// An OS-call body over plain Dart values: each argument is its
/// [MontyValue.dartValue], and the result goes back through
/// [MontyValue.fromDart].
typedef LoweredOsCall =
    Future<Object?> Function(
      String operation,
      List<Object?> args,
      Map<String, Object?> kwargs,
    );

/// Wraps [body] as an [OsHandler]. Not exported.
OsHandler loweredOsHandler(LoweredOsCall body) =>
    (operation, args, kwargs) async => MontyValue.fromDart(
      await body(
        operation,
        [for (final a in args) a.dartValue],
        {
          for (final e in kwargs.entries) e.key: e.value.dartValue,
        },
      ),
    );
