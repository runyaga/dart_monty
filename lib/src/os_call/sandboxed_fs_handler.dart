// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'dart:io';

import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBytes, MontyPath, OsCallException, OsCallHandler, resolveOpenCall;
import 'package:path/path.dart' as p;

/// Handler for `Path.*` operations against the real filesystem, restricted to
/// [root]. Paths that escape the sandbox (via `../`, absolute paths outside
/// root, or symlinks pointing outside) are rejected with a typed
/// `PermissionError` (`OsCallException`).
///
/// ```dart
/// final tmp = Directory.systemTemp.createTempSync('monty_');
/// final handler = sandboxedFsHandler(root: tmp);
/// ```
OsCallHandler sandboxedFsHandler({required Directory root}) {
  final rootExact = root.resolveSymbolicLinksSync();
  final rootWithSep = rootExact.endsWith(Platform.pathSeparator)
      ? rootExact
      : '$rootExact${Platform.pathSeparator}';

  String safePath(String op, String pythonPath) {
    final joined = p.isAbsolute(pythonPath)
        ? p.normalize(pythonPath)
        : p.normalize(p.join(rootExact, pythonPath));
    if (joined != rootExact && !joined.startsWith(rootWithSep)) {
      throw OsCallException(
        'Path escapes sandbox: $pythonPath',
        pythonExceptionType: 'PermissionError',
      );
    }
    return joined;
  }

  // RESOLVE THE NEAREST EXISTING ANCESTOR, not just the path itself.
  //
  // The old form resolved only when the path ALREADY EXISTED and fell back to
  // the lexical check otherwise. That is exactly backwards for the operations
  // that matter: creating a file under a symlinked parent has a target that
  // does not exist yet, so it took the lexical path and escaped. Measured
  // before this change, with `escape` a symlink inside the root pointing out
  // of it:
  //
  //   writeText escape/pwned.txt          -> NO EXCEPTION, file written OUTSIDE
  //   mkdir     escape/newdir             -> NO EXCEPTION
  //   writeText <root>/escape/pwned2.txt  -> NO EXCEPTION, file written OUTSIDE
  //
  // Walking up to the nearest existing ancestor closes both shapes: writing
  // THROUGH an existing symlink, and creating a new entry UNDER a symlinked
  // directory. A path whose ancestors are all inside the root cannot leave it.
  String safeResolved(String op, String pythonPath) {
    final safe = safePath(op, pythonPath);

    // The deepest ancestor that exists on disk. For an existing path that is
    // the path itself; for a new file it is the directory it lands in.
    var probe = safe;
    while (FileSystemEntity.typeSync(probe, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(probe);
      if (parent == probe) return safe; // reached the filesystem root
      probe = parent;
    }

    final resolvedAncestor = Directory(probe).resolveSymbolicLinksSync();
    if (resolvedAncestor != rootExact &&
        !resolvedAncestor.startsWith(rootWithSep)) {
      throw OsCallException(
        'Symlink escapes sandbox: $pythonPath -> $resolvedAncestor',
        pythonExceptionType: 'PermissionError',
      );
    }

    // The path itself resolves only when it exists; otherwise return the
    // lexical form, whose every existing ancestor was just proven contained.
    if (probe == safe) return resolvedAncestor;

    return safe;
  }

  return (operation, args, kwargs) async {
    switch (operation) {
      case PathOp.open:
        // Keep the Python path on the handle (no host-path leak); each
        // callback re-validates it through safePath.
        final pythonPath = osArgString(args.first);
        final mode = args.length > 1 ? osArgString(args[1]) : 'r';
        return resolveOpenCall(
          pythonPath,
          mode,
          exists: (p) =>
              FileSystemEntity.typeSync(safeResolved(operation, p)) ==
              FileSystemEntityType.file,
          isDirectory: (p) =>
              FileSystemEntity.typeSync(safeResolved(operation, p)) ==
              FileSystemEntityType.directory,
          truncate: (p) {
            File(safeResolved(operation, p))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('');
          },
          createIfMissing: (p) {
            final f = File(safeResolved(operation, p));
            if (!f.existsSync()) {
              f.parent.createSync(recursive: true);
              f.createSync();
            }
          },
        );
      case PathOp.appendText:
        final safe = safeResolved(operation, osArgString(args.first));
        final content = osArgString(args[1]);
        File(safe)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content, mode: FileMode.append);
        return content.length;
      case PathOp.appendBytes:
        final safe = safeResolved(operation, osArgString(args.first));
        final bytes = (args[1]! as List).cast<int>();
        File(safe)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes, mode: FileMode.append);
        return bytes.length;
      case PathOp.exists:
        return FileSystemEntity.typeSync(
              safePath(operation, osArgString(args.first)),
            ) !=
            FileSystemEntityType.notFound;
      case PathOp.isFile:
        return FileSystemEntity.typeSync(
              safePath(operation, osArgString(args.first)),
            ) ==
            FileSystemEntityType.file;
      case PathOp.isDir:
        return FileSystemEntity.typeSync(
              safePath(operation, osArgString(args.first)),
            ) ==
            FileSystemEntityType.directory;
      case PathOp.isSymlink:
        return FileSystemEntity.typeSync(
              safePath(operation, osArgString(args.first)),
              followLinks: false,
            ) ==
            FileSystemEntityType.link;
      case PathOp.readText:
        return File(
          safeResolved(operation, osArgString(args.first)),
        ).readAsStringSync();
      case PathOp.readBytes:
        return MontyBytes(
          File(
            safeResolved(operation, osArgString(args.first)),
          ).readAsBytesSync(),
        );
      case PathOp.writeText:
        final safe = safeResolved(operation, osArgString(args.first));
        final content = osArgString(args[1]);
        final file = File(safe);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(content);
        return content.length;
      case PathOp.writeBytes:
        final safe = safeResolved(operation, osArgString(args.first));
        final bytes = (args[1]! as List).cast<int>();
        final file = File(safe);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        return bytes.length;
      case PathOp.mkdir:
        final safe = safeResolved(operation, osArgString(args.first));
        final parents = kwargs?['parents'] as bool? ?? false;
        final existOk = kwargs?['exist_ok'] as bool? ?? false;
        final dir = Directory(safe);
        if (existOk && dir.existsSync()) return null;
        dir.createSync(recursive: parents);
        return null;
      case PathOp.unlink:
        // DELETE THE LINK ENTRY, NOT WHAT IT POINTS AT.
        //
        // `safeResolved` returns the RESOLVED path, so passing it straight to
        // `File.deleteSync()` removed the target and left the symlink behind --
        // precisely inverted from CPython, and data loss: a script removing an
        // alias destroyed the real file. Measured before this change, with
        // `alias` a symlink to `real.txt`, both inside the root:
        //
        //   unlink alias -> no exception
        //   target still exists : false   (CPython: true)
        //   link  still exists  : true    (CPython: false)
        //
        // Resolution is still used for CONTAINMENT -- a link leaving the
        // sandbox is rejected before anything is removed -- but the deletion
        // targets the lexical path, which is the entry the caller named.
        final unlinkPath = osArgString(args.first);
        safeResolved(operation, unlinkPath); // containment check only
        final unlinkAt = safePath(operation, unlinkPath);
        if (FileSystemEntity.isLinkSync(unlinkAt)) {
          Link(unlinkAt).deleteSync();
        } else {
          File(unlinkAt).deleteSync();
        }
        return null;
      case PathOp.rmdir:
        Directory(
          safeResolved(operation, osArgString(args.first)),
        ).deleteSync();
        return null;
      case PathOp.rename:
        final oldSafe = safeResolved(operation, osArgString(args.first));
        final newSafe = safePath(operation, osArgString(args[1]));
        File(oldSafe).renameSync(newSafe);
        return newSafe;
      case PathOp.iterdir:
        final safe = safePath(operation, osArgString(args.first));
        return Directory(
          safe,
        ).listSync().map((e) => MontyPath(e.path)).toList();
      case PathOp.resolve:
        return safeResolved(operation, osArgString(args.first));
      case PathOp.absolute:
        return safePath(operation, osArgString(args.first));
    }
    throw UnsupportedError('Unsupported path operation: $operation');
  };
}
