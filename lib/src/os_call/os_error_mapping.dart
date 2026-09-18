import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart'
    show OsCallException, OsCallHandler;

/// Maps a dart:io [FileSystemException] to the [OsCallException] CPython would
/// raise for the same syscall.
///
/// WHY THIS EXISTS. A raw `FileSystemException` escaping an OS-call handler
/// reaches Python as a Dart error rather than an OSError — the leak class
/// recorded at fs_handlers.dart's `OsCallNotHandledException` throw ("same
/// leak class as the bridge arm fixed in 64fb4c8").
///
/// Audited 2026-09-17 by driving every PathOp against a failing condition in
/// both handlers. Nine of ten read/delete/list operations already mapped
/// their failures; the WRITE FAMILY mapped none of them, in BOTH handlers:
///
///     fsHandler   write_text / write_bytes / append_text / append_bytes
///     sandboxed   write_text / write_bytes / append_text / append_bytes
///
/// all leaking `FileSystemException` when the path is a directory, where
/// CPython raises IsADirectoryError.
///
/// Mapping at the HANDLER BOUNDARY rather than per-operation is deliberate: it
/// is one implementation instead of eight, and an operation added later is
/// covered without anyone remembering to wrap it.
///
/// The errno values are the OS's own. They are NOT reinterpreted — see the
/// note in fs_handlers.dart's rename about EISDIR arriving where CPython would
/// say ENOTDIR, which is a separate divergence this mapping does not paper
/// over.
/// errno -> the CPython exception subclass raised for it.
///
/// A TABLE, not a switch: the mapping has no conditional logic in it, and
/// writing it as one kept the cyclomatic-complexity metric flat.
const _pythonTypeByErrno = {
  2: 'FileNotFoundError',
  13: 'PermissionError',
  17: 'FileExistsError',
  20: 'NotADirectoryError',
  21: 'IsADirectoryError',
};

OsCallException _mapFileSystemException(
  FileSystemException e, {
  required String operation,
}) {
  final os = e.osError;

  return OsCallException(
    '[Errno ${os?.errorCode}] ${os?.message ?? e.message}: '
    "'${e.path ?? operation}'",
    // Anything not in the table keeps the OS's message under a plain
    // OSError, which is what CPython does for errnos it has no dedicated
    // subclass for.
    pythonExceptionType: _pythonTypeByErrno[os?.errorCode] ?? 'OSError',
  );
}

/// Wraps [inner] so any dart:io [FileSystemException] escaping it becomes the
/// [OsCallException] CPython would raise.
///
/// A COMBINATOR, not a try/catch inside each handler, for two reasons. It keeps
/// the handler bodies byte-identical -- wrapping in place indents the whole
/// switch, which moved three DCM metrics (nesting, cyclomatic complexity, and
/// both files' issue counts) for a change that adds no branch to the operation
/// logic itself. And it composes: a new handler opts in with one call.
///
/// It catches FileSystemException ONLY. Arms that already choose a specific
/// python type -- the FileNotFoundError refusals in both handlers, rename's
/// two-path message -- throw OsCallException and pass straight through, and
/// OsCallNotHandledException still reaches `composeOsHandlers` so a sibling
/// handler can answer. Broadening this catch would silently undo all three.
OsCallHandler mapIoErrors(OsCallHandler inner) {
  return (operation, args, kwargs) async {
    try {
      return await inner(operation, args, kwargs);
    } on FileSystemException catch (e) {
      throw _mapFileSystemException(e, operation: operation);
    }
  };
}
