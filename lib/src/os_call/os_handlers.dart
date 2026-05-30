import 'package:dart_monty_core/dart_monty_core.dart' show OsCallHandler;

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

  return (operation, args, kwargs) {
    // `open()` is a filesystem op without a `Path.` prefix — route it to the
    // filesystem handler so handlers don't each register a separate 'Open' key.
    if (operation == 'Open' && pathHandler != null) {
      return pathHandler(operation, args, kwargs);
    }
    for (final prefix in sortedPrefixes) {
      if (operation.startsWith(prefix)) {
        return handlers[prefix]!(operation, args, kwargs);
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
