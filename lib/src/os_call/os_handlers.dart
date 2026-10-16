// A composer must stay synchronous: core honours an OsCallNotHandledException
// only as a synchronous throw, so the handlers' results are returned as they
// are, never awaited. `prefer-return-await` would force an `async` frame.
// ignore_for_file: prefer-return-await
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show OsCallNotHandledException, OsHandler;

export 'package:dart_monty_core/dart_monty_core.dart' show OsHandler;

/// Composes multiple [OsHandler]s by operation-name prefix.
///
/// Each key maps a prefix (e.g., `'Path.'`, `'os.'`) to the handler
/// responsible for that group. Longest prefix wins. Unmatched operations are
/// routed to [fallback]; with no fallback the composer throws
/// [OsCallNotHandledException] — it declines rather than failing, so composers
/// can be nested and a handler that throws it is treated as "not mine". Only
/// a synchronous throw declines: a returned `Future` that fails with it does
/// not, as in core.
///
/// The bare `open` op (Python's `open()`, which carries no `Path.` prefix) is
/// routed to the `'Path.'` handler when one is registered — `open()` is a
/// filesystem operation, so callers wire it the same way they wire `Path.*`.
///
/// ```dart
/// final os = composeOsHandlers({
///   'Path.': fsHandler(MemoryFileSystem()),
///   'os.': envHandler(const {}),
/// });
/// ```
OsHandler composeOsHandlers(
  Map<String, OsHandler> handlers, {
  OsHandler? fallback,
}) {
  final sortedPrefixes = handlers.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final pathHandler = handlers['Path.'];

  // NOT `async`. Core honours an [OsCallNotHandledException] only as a
  // synchronous throw (a returned Future that fails with it raises
  // `TypeError`), so the composer catches a decline synchronously and declines
  // synchronously. A handler that returns a Future is passed through as is.
  return (operation, args, kwargs) {
    // `open()` is a filesystem op without a `Path.` prefix — route it to the
    // filesystem handler so handlers don't each register a separate key for it.
    // Compare against the constant, never a literal: monty v0.0.19 renamed this
    // op from `'Open'` to `'open'`, and the failure is silent — a stale literal
    // stops matching and falls through with no error.
    if (operation == PathOp.open && pathHandler != null) {
      try {
        return pathHandler(operation, args, kwargs);
      } on OsCallNotHandledException {
        // Declined — fall through to prefix matching.
      }
    }
    for (final prefix in sortedPrefixes) {
      if (operation.startsWith(prefix)) {
        try {
          return handlers[prefix]!(operation, args, kwargs);
        } on OsCallNotHandledException {
          // Declined. Keep going: a shorter registered prefix may handle it,
          // and failing that the fallback should get a turn. Only this one
          // exception is caught — a genuine error still propagates.
          continue;
        }
      }
    }
    if (fallback != null) return fallback(operation, args, kwargs);
    // DECLINE, do not fail. A composer is itself an `OsHandler` and this
    // codebase nests them, so an exhausted composer must let an outer one try
    // the next candidate. The worker then answers with the call's own default.
    throw const OsCallNotHandledException();
  };
}

/// Extracts a string argument from a positional slot.
///
/// Accepts `String` values (a lowered `MontyPath` or `MontyString`).
String osArgString(Object? arg) =>
    arg is String ? arg : throw ArgumentError('Expected string, got: $arg');
