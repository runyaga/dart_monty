// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyPath, OsCallHandler;

/// Write operations blocked by [readOnlyHandler].
const Set<String> _writeOps = {
  PathOp.writeText,
  PathOp.writeBytes,
  PathOp.mkdir,
  PathOp.unlink,
  PathOp.rmdir,
  PathOp.rename,
};

/// Wraps an [OsCallHandler] and blocks write operations.
///
/// Read operations, environment access, and datetime pass through unchanged.
/// Write operations throw [OsCallPermissionError].
///
/// ```dart
/// final ro = readOnlyHandler(fsHandler(const LocalFileSystem()));
/// ```
OsCallHandler readOnlyHandler(OsCallHandler inner) {
  return (operation, args, kwargs) {
    if (_writeOps.contains(operation)) {
      throw OsCallPermissionError(operation, 'Read-only filesystem');
    }
    return inner(operation, args, kwargs);
  };
}

/// Two-layer filesystem: reads fall through to [base], writes go to [scratch].
///
/// Copy-on-write semantics — Python can read files from the base layer
/// (e.g., real project files) while all modifications are captured in the
/// scratch layer (e.g., in-memory VFS). The base layer is never modified.
///
/// ```dart
/// final scratch = MemoryVfs();
/// final overlay = overlayFsHandler(
///   base: sandboxedFsHandler(root: projectDir),
///   scratch: scratch.handler,
/// );
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
OsCallHandler overlayFsHandler({
  required OsCallHandler base,
  required OsCallHandler scratch,
}) {
  Future<Object?> readWithFallback(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    try {
      return await scratch(op, args, kwargs);
    } on OsCallFileNotFoundError {
      return base(op, args, kwargs);
    }
  }

  Future<Object?> queryWithFallback(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    final scratchResult = await scratch(op, args, kwargs);
    if (scratchResult == true) return true;
    return base(op, args, kwargs);
  }

  Future<Object?> mergedIterdir(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    final seen = <String>{};
    final merged = <MontyPath>[];

    try {
      final scratchEntries = await scratch(op, args, kwargs);
      if (scratchEntries is List<MontyPath>) {
        for (final entry in scratchEntries) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    } on OsCallFileNotFoundError {
      // Scratch dir doesn't exist — that's fine.
    }

    try {
      final baseEntries = await base(op, args, kwargs);
      if (baseEntries is List<MontyPath>) {
        for (final entry in baseEntries) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    } on OsCallFileNotFoundError {
      if (merged.isEmpty) {
        final path = args.isNotEmpty ? args.first : '';
        final pathStr = path is String ? path : '';
        throw OsCallFileNotFoundError(op, 'No such directory: $pathStr');
      }
    }

    return merged;
  }

  Future<Object?> deleteFromScratch(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    try {
      return await scratch(op, args, kwargs);
    } on OsCallFileNotFoundError {
      final existsInBase = await base(PathOp.exists, args, kwargs);
      if (existsInBase == true) {
        throw OsCallPermissionError(
          op,
          'Cannot delete base-layer file (read-only)',
        );
      }
      rethrow;
    }
  }

  return (operation, args, kwargs) {
    return switch (operation) {
      PathOp.writeText ||
      PathOp.writeBytes ||
      PathOp.mkdir ||
      PathOp.rename => scratch(operation, args, kwargs),
      PathOp.readText ||
      PathOp.readBytes => readWithFallback(operation, args, kwargs),
      PathOp.exists ||
      PathOp.isFile ||
      PathOp.isDir ||
      PathOp.isSymlink => queryWithFallback(operation, args, kwargs),
      PathOp.iterdir => mergedIterdir(operation, args, kwargs),
      PathOp.unlink ||
      PathOp.rmdir => deleteFromScratch(operation, args, kwargs),
      _ => base(operation, args, kwargs),
    };
  };
}
