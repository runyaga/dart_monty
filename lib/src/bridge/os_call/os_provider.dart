import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/default_sandbox_os.dart';

/// Interface for resolving OS-level calls from sandboxed Python code.
///
/// OS calls are triggered implicitly when Python accesses standard library
/// modules like `pathlib`, `os`, or `datetime`. The interpreter pauses and
/// yields a [MontyOsCall] describing the operation. The bridge invokes
/// [resolve] and resumes Python with the returned value.
///
/// Use the default constructor for the platform-appropriate provider:
/// ```dart
/// final monty = Monty(os: OsProvider());
/// ```
///
/// - **Native:** Full filesystem via `LocalFileSystem` + environment + datetime
/// - **Web:** In-memory VFS via `MemoryFileSystem` + datetime (no env)
///
/// For custom composition:
/// ```dart
/// final monty = Monty(os: OsProvider.compose({
///   'Path.': MemoryFsProvider(),
///   'date.': TimeOsProvider(),
/// }));
/// ```
///
/// Implementations should throw `OsCallException` (or subclasses) for
/// domain errors (file not found, permission denied, etc.). The bridge
/// translates these into the corresponding Python exception types.
abstract class OsProvider {
  /// Creates the platform-appropriate default provider.
  ///
  /// - **Native:** `LocalFileSystem` + `Platform.environment` + datetime
  /// - **Web:** `MemoryFileSystem` + datetime (no env access)
  factory OsProvider() => defaultSandboxOs();

  /// Generative constructor for subclasses.
  const OsProvider.base();

  /// Resolves the OS call and returns the result to resume Python.
  ///
  /// Throw an `OsCallException` to resume Python with a typed error.
  Future<Object?> resolve(MontyOsCall call);

  /// Lifecycle hook called when the bridge is disposed.
  ///
  /// Override to release resources (temp directories, open files, etc.).
  Future<void> dispose() async {}

  /// Returns the provider registered for [prefix], or `null`.
  ///
  /// Only composite providers (created via [compose]) return non-null.
  /// Leaf providers always return `null`.
  OsProvider? providerFor(String prefix) => null;

  /// Composes multiple providers by operation-name prefix.
  ///
  /// Each key maps a prefix (e.g., `'Path.'`, `'os.'`, `'date.'`) to the
  /// provider responsible for that group. Longest prefix match wins.
  ///
  /// ```dart
  /// final os = OsProvider.compose({
  ///   'Path.': MemoryFsProvider(),
  ///   'date.': TimeOsProvider(),
  ///   'datetime.': TimeOsProvider(),
  /// });
  /// ```
  static OsProvider compose(
    Map<String, OsProvider> providers, {
    OsProvider? fallback,
  }) => _CompositeOsProvider(providers, fallback: fallback);
}

/// Routes [MontyOsCall] operations to child providers based on prefix matching.
///
/// Each entry in [providers] maps an operation name prefix (e.g., `'Path.'`,
/// `'os.'`, `'date.'`) to the [OsProvider] responsible for that group.
///
/// When multiple prefixes match, the longest prefix wins. If no prefix
/// matches, the [fallback] provider is invoked. If no fallback is configured,
/// an [UnsupportedError] is thrown.
class _CompositeOsProvider extends OsProvider {
  /// Creates a composite provider with the given prefix-to-provider mapping.
  ///
  /// [fallback] is invoked for operations that don't match any prefix.
  _CompositeOsProvider(this.providers, {this.fallback}) : super.base();

  /// Prefix-to-provider mapping, checked longest-prefix-first.
  final Map<String, OsProvider> providers;

  /// Optional fallback for unmatched operations.
  final OsProvider? fallback;

  /// Sorted prefixes, longest first (computed lazily).
  late final List<String> _sortedPrefixes = providers.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));

  @override
  OsProvider? providerFor(String prefix) => providers[prefix];

  @override
  Future<Object?> resolve(MontyOsCall call) {
    final op = call.operationName;

    for (final prefix in _sortedPrefixes) {
      if (op.startsWith(prefix)) {
        return providers[prefix]!.resolve(call);
      }
    }

    if (fallback != null) return fallback!.resolve(call);

    throw UnsupportedError('No handler for OS operation: $op');
  }

  @override
  Future<void> dispose() async {
    final seen = <OsProvider>{};
    for (final provider in providers.values) {
      // Same provider may be registered under multiple prefixes.
      if (seen.add(provider)) await provider.dispose();
    }
    await fallback?.dispose();
  }
}
