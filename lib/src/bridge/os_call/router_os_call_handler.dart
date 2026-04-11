import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';

/// Routes [MontyOsCall] operations to child handlers based on prefix matching.
///
/// Each entry in [handlers] maps an operation name prefix (e.g., `'Path.'`,
/// `'os.'`, `'date.'`) to the [OsCallHandler] responsible for that group.
///
/// When multiple prefixes match, the longest prefix wins. If no prefix
/// matches, the [fallback] handler is invoked. If no fallback is configured,
/// an [UnsupportedError] is thrown.
///
/// ```dart
/// final router = RouterOsCallHandler({
///   'Path.': memoryFsHandler,
///   'os.': envHandler,
///   'date.': timeHandler,
///   'datetime.': timeHandler,
/// });
/// ```
class RouterOsCallHandler extends OsCallHandler {
  /// Creates a router with the given prefix-to-handler mapping.
  ///
  /// [fallback] is invoked for operations that don't match any prefix.
  RouterOsCallHandler(this.handlers, {this.fallback});

  /// Prefix-to-handler mapping, checked longest-prefix-first.
  final Map<String, OsCallHandler> handlers;

  /// Optional fallback for unmatched operations.
  final OsCallHandler? fallback;

  /// Sorted prefixes, longest first (computed lazily).
  late final List<String> _sortedPrefixes = handlers.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  /// Returns the handler registered for [prefix], or `null`.
  OsCallHandler? handlerFor(String prefix) => handlers[prefix];

  @override
  Future<Object?> handle(MontyOsCall call) {
    final op = call.operationName;

    for (final prefix in _sortedPrefixes) {
      if (op.startsWith(prefix)) {
        return handlers[prefix]!.handle(call);
      }
    }

    if (fallback != null) return fallback!.handle(call);

    throw UnsupportedError('No handler for OS operation: $op');
  }

  @override
  Future<void> dispose() async {
    final seen = <OsCallHandler>{};
    for (final handler in handlers.values) {
      // Same handler may be registered under multiple prefixes.
      if (seen.add(handler)) await handler.dispose();
    }
    await fallback?.dispose();
  }
}
