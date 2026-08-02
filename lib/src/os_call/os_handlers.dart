import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show OsCallHandler, OsCallNotHandledException;

export 'package:dart_monty_core/dart_monty_core.dart' show OsCallHandler;

/// Composes multiple [OsCallHandler]s by operation-name prefix.
///
/// Each key maps a prefix (e.g., `'Path.'`, `'os.'`, `'date.'`) to the handler
/// responsible for that group. Longest prefix wins. Unmatched operations are
/// routed to [fallback], or throw [UnsupportedError] if none is configured.
///
/// The bare `Open` op (Python's `open()`, which carries no `Path.` prefix) is
/// routed to the `'Path.'` handler when one is registered — `open()` is a
/// filesystem operation, so callers wire it the same way they wire `Path.*`.
///
/// ```dart
/// final os = composeOsHandlers({
///   'Path.': fsHandler(MemoryFileSystem()),
///   'date.': timeHandler(),
///   'datetime.': timeHandler(),
/// });
/// ```
OsCallHandler composeOsHandlers(
  Map<String, OsCallHandler> handlers, {
  OsCallHandler? fallback,
}) {
  final sortedPrefixes = handlers.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final pathHandler = handlers['Path.'];

  // `async` so a handler's [OsCallNotHandledException] can be awaited and
  // treated as "not mine". Returning the handler's future directly made
  // declining impossible: the exception escaped as a failure and routing
  // stopped, so `OsCallNotHandledException` — which core documents as the way
  // to decline — could not be used by a composed handler at all.
  return (operation, args, kwargs) async {
    // `open()` is a filesystem op without a `Path.` prefix — route it to the
    // filesystem handler so handlers don't each register a separate key for it.
    // Compare against the constant, never a literal: monty v0.0.19 renamed this
    // op from `'Open'` to `'open'`, and the failure is silent — a stale literal
    // stops matching and falls through with no error.
    if (operation == PathOp.open && pathHandler != null) {
      try {
        return await pathHandler(operation, args, kwargs);
      } on OsCallNotHandledException {
        // Declined — fall through to prefix matching.
      }
    }
    for (final prefix in sortedPrefixes) {
      if (operation.startsWith(prefix)) {
        try {
          return await handlers[prefix]!(operation, args, kwargs);
        } on OsCallNotHandledException {
          // Declined. Keep going: a shorter registered prefix may handle it,
          // and failing that the fallback should get a turn. Only this one
          // exception is caught — a genuine error still propagates.
          continue;
        }
      }
    }
    if (fallback != null) return fallback(operation, args, kwargs);
    throw UnsupportedError('No handler for OS operation: $operation');
  };
}

/// Extracts a string argument from a positional slot.
///
/// Accepts `String` values (including unwrapped `MontyPath`/`MontyString`).
String osArgString(Object? arg) =>
    arg is String ? arg : throw ArgumentError('Expected string, got: $arg');
