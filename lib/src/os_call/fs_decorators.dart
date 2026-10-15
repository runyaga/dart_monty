// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'dart:async';

import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty/src/os_call/sync_or_async.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        ExternalException,
        MontyBool,
        MontyList,
        MontyPath,
        MontyString,
        MontyValue,
        OsHandler;

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
    e is ExternalException && e.excType == 'FileNotFoundError';

/// Whether an `Open` call requests a write/append mode (`w`/`a` families).
bool _opensForWrite(String operation, List<MontyValue> args) {
  if (operation != PathOp.open) return false;
  final mode = args.length > 1
      ? switch (args[1]) {
          MontyString(:final value) => value,
          _ => 'r',
        }
      : 'r';
  return mode != 'r' && mode != 'rb';
}

/// Wraps an [OsHandler] and blocks write operations.
///
/// Read operations, environment access, and datetime pass through unchanged.
/// Writes — including `open(..., 'w'/'a')` — throw a typed `PermissionError`.
///
/// ```dart
/// final ro = readOnlyHandler(fsHandler(const LocalFileSystem()));
/// ```
OsHandler readOnlyHandler(OsHandler inner) {
  return (operation, args, kwargs) {
    if (_writeOps.contains(operation) || _opensForWrite(operation, args)) {
      throw const ExternalException('PermissionError', 'Read-only filesystem');
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
OsHandler overlayFsHandler({
  required OsHandler base,
  required OsHandler scratch,
}) {
  // None of the helpers below is `async`: a decline thrown by a layer must
  // stay a synchronous throw (the only form core honours), and a layer's
  // synchronous answer must stay synchronous. `recoverFrom` and `thenOrNow`
  // go asynchronous only when a layer returns a `Future`.

  FutureOr<MontyValue> readWithFallback(
    String op,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => recoverFrom<MontyValue>(
    () => scratch(op, args, kwargs),
    test: _isNotFound,
    onError: (_, _) => base(op, args, kwargs),
  );

  FutureOr<MontyValue> queryWithFallback(
    String op,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => thenOrNow<MontyValue, MontyValue>(
    scratch(op, args, kwargs),
    (scratchResult) => scratchResult is MontyBool && scratchResult.value
        ? scratchResult
        : base(op, args, kwargs),
  );

  FutureOr<MontyValue> mergedIterdir(
    String op,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    final seen = <String>{};
    final merged = <MontyPath>[];

    void addEntries(MontyValue entries) {
      if (entries case MontyList(:final items)) {
        for (final entry in items.whereType<MontyPath>()) {
          if (seen.add(entry.value)) merged.add(entry);
        }
      }
    }

    // A missing scratch directory is fine: only the base layer contributes.
    FutureOr<void> fromScratch() => thenOrNow<MontyValue, void>(
      recoverFrom<MontyValue>(
        () => scratch(op, args, kwargs),
        test: _isNotFound,
        onError: (_, _) => const MontyList([]),
      ),
      addEntries,
    );

    // A missing base directory is an error only when scratch had nothing.
    FutureOr<MontyValue> fromBase() => thenOrNow<MontyValue, MontyValue>(
      recoverFrom<MontyValue>(
        () => base(op, args, kwargs),
        test: _isNotFound,
        onError: (_, _) {
          if (merged.isEmpty) {
            final path = args.firstOrNull?.dartValue;
            final pathStr = path is String ? path : '';
            throw ExternalException(
              'FileNotFoundError',
              'No such directory: $pathStr',
            );
          }

          return const MontyList([]);
        },
      ),
      (baseEntries) {
        addEntries(baseEntries);

        return MontyList(merged);
      },
    );

    return thenOrNow<void, MontyValue>(fromScratch(), (_) => fromBase());
  }

  FutureOr<MontyValue> deleteFromScratch(
    String op,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => recoverFrom<MontyValue>(
    () => scratch(op, args, kwargs),
    test: _isNotFound,
    onError: (notFound, stack) => thenOrNow<MontyValue, MontyValue>(
      base(PathOp.exists, args, kwargs),
      (existsInBase) {
        if (existsInBase case MontyBool(value: true)) {
          throw const ExternalException(
            'PermissionError',
            'Cannot delete base-layer file (read-only)',
          );
        }
        Error.throwWithStackTrace(notFound, stack);
      },
    ),
  );

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

/// Fluent composition helpers for [OsHandler].
///
/// ```dart
/// // Instead of:
/// overlayFsHandler(base: readOnlyHandler(fsHandler(baseFs)), scratch: scratch)
///
/// // Write:
/// fsHandler(baseFs).readOnly().overlayWith(scratch)
/// ```
extension DecoratorHandlers on OsHandler {
  /// Wraps this handler so write operations throw a typed PermissionError.
  OsHandler readOnly() => readOnlyHandler(this);

  /// Uses this handler as the read-only base of a copy-on-write overlay.
  ///
  /// Writes go to [scratch]; reads fall through to this handler on miss.
  OsHandler overlayWith(OsHandler scratch) =>
      overlayFsHandler(base: this, scratch: scratch);
}
