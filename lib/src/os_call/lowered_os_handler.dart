import 'dart:async';

import 'package:dart_monty/src/os_call/sync_or_async.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyValue, OsHandler;

/// Wraps [body] as an [OsHandler] over plain Dart values: each argument is its
/// [MontyValue.dartValue], and the result goes back through
/// [MontyValue.fromDart].
///
/// The body is NOT `async`: it answers synchronously, or throws, and a
/// synchronous throw of `OsCallNotHandledException` is how it declines. It
/// may return a `Future` when its answer is not ready.
///
/// Not exported.
///
/// Synchronous in, synchronous out: a decline thrown by [body] reaches the
/// caller as a throw, never as a failed `Future`.
OsHandler loweredOsHandler(
  FutureOr<Object?> Function(
    String operation,
    List<Object?> args,
    Map<String, Object?> kwargs,
  )
  body,
) =>
    (operation, args, kwargs) => thenOrNow<Object?, MontyValue>(
      body(
        operation,
        [for (final a in args) a.dartValue],
        {for (final e in kwargs.entries) e.key: e.value.dartValue},
      ),
      MontyValue.fromDart,
    );
