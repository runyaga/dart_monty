// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyPath, OsCallException, OsCallHandler;

/// Write operations blocked by [readOnlyHandler].
const Set<String> _writeOps = {
  PathOp.writeText,
  PathOp.writeBytes,
  PathOp.appendText,
  PathOp.appendBytes,
  PathOp.mkdir,
  PathOp.unlink,
  PathOp.rmdir,
  PathOp.rename,
};

/// Whether a thrown error is a typed `FileNotFoundError` from a handler.
bool _isNotFound(Object e) =>
    e is OsCallException && e.pythonExceptionType == 'FileNotFoundError';

/// Whether an `Open` call requests a write/append mode (`w`/`a` families).
bool _opensForWrite(String operation, List<Object?> args) {
  if (operation != PathOp.open) return false;
  final mode = args.length > 1 && args[1] is String ? args[1]! as String : 'r';
  return mode != 'r' && mode != 'rb';
}

/// Wraps an [OsCallHandler] and blocks write operations.
///
/// Read operations, environment access, and datetime pass through unchanged.
/// Writes — including `open(..., 'w'/'a')` — throw a typed `PermissionError`.
///
/// ```dart
/// final ro = readOnlyHandler(fsHandler(const LocalFileSystem()));
/// ```
OsCallHandler readOnlyHandler(OsCallHandler inner) {
  return (operation, args, kwargs) {
    if (_writeOps.contains(operation) || _opensForWrite(operation, args)) {
      throw const OsCallException(
        'Read-only filesystem',
        pythonExceptionType: 'PermissionError',
      );
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
    } on OsCallException catch (e) {
      if (!_isNotFound(e)) rethrow;
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
    } on OsCallException catch (e) {
      if (!_isNotFound(e)) rethrow;
      // Scratch dir doesn't exist — that's fine.
    }

    try {
      final baseEntries = await base(op, args, kwargs);
      if (baseEntries is List<MontyPath>) {
        for (final entry in baseEntries) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    } on OsCallException catch (e) {
      if (!_isNotFound(e)) rethrow;
      if (merged.isEmpty) {
        final path = args.isNotEmpty ? args.first : '';
        final pathStr = path is String ? path : '';
        throw OsCallException(
          'No such directory: $pathStr',
          pythonExceptionType: 'FileNotFoundError',
        );
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
    } on OsCallException catch (e) {
      if (!_isNotFound(e)) rethrow;
      final existsInBase = await base(PathOp.exists, args, kwargs);
      if (existsInBase == true) {
        throw const OsCallException(
          'Cannot delete base-layer file (read-only)',
          pythonExceptionType: 'PermissionError',
        );
      }
      rethrow;
    }
  }

  return (operation, args, kwargs) {
    return switch (operation) {
      PathOp.open =>
        _opensForWrite(operation, args)
            ? scratch(operation, args, kwargs)
            : readWithFallback(operation, args, kwargs),
      PathOp.writeText ||
      PathOp.writeBytes ||
      PathOp.appendText ||
      PathOp.appendBytes ||
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

/// Fluent composition helpers for [OsCallHandler].
///
/// ```dart
/// // Instead of:
/// overlayFsHandler(base: readOnlyHandler(fsHandler(baseFs)), scratch: scratch)
///
/// // Write:
/// fsHandler(baseFs).readOnly().overlayWith(scratch)
/// ```
extension DecoratorHandlers on OsCallHandler {
  /// Wraps this handler so write operations throw a typed PermissionError.
  OsCallHandler readOnly() => readOnlyHandler(this);

  /// Uses this handler as the read-only base of a copy-on-write overlay.
  ///
  /// Writes go to [scratch]; reads fall through to this handler on miss.
  OsCallHandler overlayWith(OsCallHandler scratch) =>
      overlayFsHandler(base: this, scratch: scratch);
}
