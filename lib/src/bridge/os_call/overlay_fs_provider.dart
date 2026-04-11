// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';

/// Two-layer filesystem: reads fall through to [base], writes go to [scratch].
///
/// Copy-on-write semantics — Python can read files from the base layer
/// (e.g., real project files) while all modifications are captured in the
/// scratch layer (e.g., in-memory VFS). The base layer is never modified.
///
/// After execution, inspect [scratch] to see what Python wrote without
/// it touching the original files.
///
/// ```dart
/// final scratch = MemoryFsProvider();
/// final overlay = OverlayFsProvider(
///   base: SandboxedFsProvider(root: projectDir),
///   scratch: scratch,
/// );
/// final monty = Monty(os: OsProvider.compose({
///   'Path.': overlay,
///   'date.': TimeOsProvider(),
/// }));
///
/// await monty.run(agentCode);
///
/// // Inspect what the agent wrote
/// final output = scratch.fileSystem.file('/src/main.py').readAsStringSync();
/// ```
///
/// **Semantics:**
/// - `exists/is_file/is_dir` — check scratch first, fall through to base
/// - `read_text/read_bytes` — check scratch first, fall through to base
/// - `write_text/write_bytes/mkdir` — always go to scratch
/// - `iterdir` — merge both layers, deduplicate
/// - `unlink/rmdir` on base-only file — throws (no whiteout support)
/// - `rename` — only works within scratch layer
/// - `resolve/absolute` — delegates to base (path resolution)
class OverlayFsProvider extends OsProvider {
  /// Creates an overlay with [base] for reads and [scratch] for writes.
  const OverlayFsProvider({required this.base, required this.scratch})
    : super.base();

  /// The read-only base layer (never modified).
  final OsProvider base;

  /// The writable scratch layer (captures all modifications).
  final OsProvider scratch;

  @override
  Future<Object?> resolve(MontyOsCall call) {
    return switch (call.operationName) {
      // Writes + rename → scratch
      'Path.write_text' ||
      'Path.write_bytes' ||
      'Path.mkdir' ||
      'Path.rename' => scratch.resolve(call),

      // Reads → scratch first, fall through to base
      'Path.read_text' || 'Path.read_bytes' => _readWithFallback(call),

      // Queries → scratch first, fall through to base
      'Path.exists' ||
      'Path.is_file' ||
      'Path.is_dir' ||
      'Path.is_symlink' => _queryWithFallback(call),

      // Listing → merge both layers
      'Path.iterdir' => _mergedIterdir(call),

      // Delete → scratch only (no whiteout)
      'Path.unlink' || 'Path.rmdir' => _deleteFromScratch(call),

      // Everything else (resolve, absolute, env, datetime) → base
      _ => base.resolve(call),
    };
  }

  @override
  Future<void> dispose() async {
    await scratch.dispose();
    await base.dispose();
  }

  /// Tries scratch first; if file not found, falls through to base.
  Future<Object?> _readWithFallback(MontyOsCall call) async {
    try {
      return await scratch.resolve(call);
    } on OsCallFileNotFoundError {
      return base.resolve(call);
    }
  }

  /// Checks scratch first; if false/not-found, checks base.
  Future<Object?> _queryWithFallback(MontyOsCall call) async {
    final scratchResult = await scratch.resolve(call);
    if (scratchResult == true) return true;

    return base.resolve(call);
  }

  /// Merges iterdir results from both layers, deduplicates by path.
  Future<Object?> _mergedIterdir(MontyOsCall call) async {
    final seen = <String>{};
    final merged = <MontyPath>[];

    // Scratch first (takes precedence)
    try {
      final scratchEntries = await scratch.resolve(call);
      if (scratchEntries is List<MontyPath>) {
        for (final entry in scratchEntries) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    } on OsCallFileNotFoundError {
      // Scratch dir doesn't exist — that's fine
    }

    // Then base
    try {
      final baseEntries = await base.resolve(call);
      if (baseEntries is List<MontyPath>) {
        for (final entry in baseEntries) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    } on OsCallFileNotFoundError {
      // Base dir doesn't exist either — if scratch also didn't, throw
      if (merged.isEmpty) {
        final path = call.arguments.isNotEmpty
            ? call.arguments.first
            : const MontyString('');
        final pathStr = switch (path) {
          MontyString(:final value) || MontyPath(:final value) => value,
          _ => '',
        };
        throw OsCallFileNotFoundError(
          'Path.iterdir',
          'No such directory: $pathStr',
        );
      }
    }

    return merged;
  }

  /// Deletes from scratch only. If the file only exists in base, throws.
  Future<Object?> _deleteFromScratch(MontyOsCall call) async {
    try {
      return await scratch.resolve(call);
    } on OsCallFileNotFoundError {
      // Check if it exists in base — give a clear error
      final existsCall = MontyOsCall(
        operationName: 'Path.exists',
        arguments: call.arguments,
      );
      final existsInBase = await base.resolve(existsCall);
      if (existsInBase == true) {
        throw OsCallPermissionError(
          call.operationName,
          'Cannot delete base-layer file (read-only)',
        );
      }
      rethrow;
    }
  }
}
