// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'dart:io';

import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        MontyBytes,
        MontyPath,
        OsCallException,
        OsCallHandler,
        OsCallNotHandledException,
        resolveOpenCall;
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
        return _codepointCount(content);
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
        return _codepointCount(content);
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
        // SAME SHAPE AS unlink, SAME INVERSION. `safeResolved` returns the
        // RESOLVED path, so `rmdir` on a symlink-to-a-directory followed the
        // link and deleted the REAL directory, leaving the link behind.
        // Measured before this change, with `dirlink` -> `realdir`, both
        // inside the root and realdir EMPTY:
        //
        //   rmdir dirlink       -> no exception   (CPython: NotADirectoryError)
        //   real dir still exists : false         (CPython: true)
        //   link still exists     : true
        //
        // A first probe hid this by leaving a file in realdir: the delete then
        // failed with "directory not empty", which looks like correct refusal
        // and is not.
        //
        // CPython raises NotADirectoryError for rmdir on a symlink, even when
        // it points at a directory -- the link is not itself a directory.
        final rmdirPath = osArgString(args.first);
        safeResolved(operation, rmdirPath); // containment check only
        final rmdirAt = safePath(operation, rmdirPath);
        if (FileSystemEntity.isLinkSync(rmdirAt)) {
          throw OsCallException(
            'Not a directory: $rmdirPath',
            pythonExceptionType: 'NotADirectoryError',
          );
        }
        Directory(rmdirAt).deleteSync();
        return null;
      case PathOp.rename:
        // CPython's rename is four errors and one SILENT OVERWRITE, depending
        // on what sits at each end. This was `File(old).renameSync(new)` —
        // four lines that always treated the source as a FILE, so renaming a
        // DIRECTORY failed outright and every error surfaced as a bare
        // RuntimeError carrying a Dart message. Measured before this change:
        //
        //   src      dst             CPython              was
        //   -------  --------------  -------------------  ------------
        //   missing  -               FileNotFoundError    RuntimeError
        //   file     missing         move                 ok
        //   file     file            silent OVERWRITE     ok
        //   file     dir             IsADirectoryError    RuntimeError
        //   dir      missing         move                 RuntimeError
        //   dir      file            NotADirectoryError   RuntimeError
        //   dir      non-empty dir   [Errno 39]           RuntimeError
        //   dir      empty dir       move, replacing it   RuntimeError
        //
        // dart_monty_core implements the same matrix and cites the fixtures
        // that assert each message (memory_mounted_os_handler.dart:594-605).
        final srcArg = osArgString(args.first);
        final dstArg = osArgString(args[1]);
        final oldSafe = safeResolved(operation, srcArg);
        final newSafe = safePath(operation, dstArg);
        final srcType = FileSystemEntity.typeSync(oldSafe);
        final dstType = FileSystemEntity.typeSync(newSafe);

        if (srcType == FileSystemEntityType.notFound) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$srcArg'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        if (srcType == FileSystemEntityType.directory) {
          switch (dstType) {
            case FileSystemEntityType.file:
              throw OsCallException(
                "[Errno 20] Not a directory: '$dstArg'",
                pythonExceptionType: 'NotADirectoryError',
              );
            case FileSystemEntityType.directory:
              final target = Directory(newSafe);
              if (target.listSync().isNotEmpty) {
                throw OsCallException(
                  "[Errno 39] Directory not empty: '$dstArg'",
                  pythonExceptionType: 'OSError',
                );
              }
              target.deleteSync();
            case FileSystemEntityType.notFound:
            case FileSystemEntityType.link:
            case FileSystemEntityType.unixDomainSock:
            case FileSystemEntityType.pipe:
              break;
          }
          Directory(oldSafe).renameSync(newSafe);
          return newSafe;
        }
        if (dstType == FileSystemEntityType.directory) {
          throw OsCallException(
            "[Errno 21] Is a directory: '$dstArg'",
            pythonExceptionType: 'IsADirectoryError',
          );
        }
        // file -> file is a SILENT overwrite; POSIX semantics, and what
        // File.renameSync already does.
        // RETURN TYPE DELIBERATELY UNCHANGED. This returns the new path as a
        // String, as it always has. Three implementations disagree about what
        // rename should return -- CPython gives the new Path, dart_monty_core
        // returns null (memory_mounted_os_handler.dart), and this returns a
        // String -- and picking one is a contract decision, not part of fixing
        // the outcome matrix. Changing it here would have swapped one
        // divergence for another.
        File(oldSafe).renameSync(newSafe);
        return newSafe;
      case PathOp.iterdir:
        final safe = safePath(operation, osArgString(args.first));
        return Directory(
          safe,
        ).listSync().map((e) => MontyPath(e.path)).toList();
      case PathOp.resolve:
        // A Path, not a str — CPython's resolve()/absolute() return
        // pathlib.Path. Returning a bare String meant Python got a `str`, so
        // `.name`, `.parent`, `.suffix` on the result raised AttributeError.
        // dart_monty_core hit exactly this and records it at
        // memory_mounted_os_handler.dart:461-470. `iterdir` in this same
        // switch already returns MontyPath; these two did not.
        return MontyPath(safeResolved(operation, osArgString(args.first)));
      case PathOp.absolute:
        return MontyPath(safePath(operation, osArgString(args.first)));
    }
    // DECLINE, DO NOT FAIL. `composeOsHandlers` treats
    // OsCallNotHandledException as "not mine" so the next handler -- or the
    // call's documented default -- can answer; its own doc says so. Throwing
    // UnsupportedError instead defeated that protocol twice over: a composed
    // sibling never got the chance to handle the op, and the Dart type name
    // leaked into the sandbox. Measured before this change:
    //
    //   Path('a.txt').stat().st_size
    //     -> RuntimeError: Unsupported operation: Unsupported path operation:
    //        Path.stat
    //
    // Same leak class as the bridge arm fixed in 64fb4c8.
    throw OsCallNotHandledException(operation);
  };
}

/// Codepoints, not UTF-16 code units — what CPython's `len()` counts.
///
/// `Path.write_text()` and `Path.append_text()` return the number of CHARACTERS
/// written. Dart's `String.length` is UTF-16 code units, so anything outside
/// the BMP — an emoji, most CJK extension blocks — counts twice. Measured:
/// `'hi \u{1F600}!'` has `String.length == 6` and `runes.length == 5`, and
/// CPython's `len()` is 5.
///
/// The three lengths in play agree for ASCII, which is exactly why this hid.
/// dart_monty_core fixed the same bug in its own handler and documents it at
/// `memory_mounted_os_handler.dart:730` (`_codepointCount`); that helper is
/// private to core, so this is the same one-liner rather than a reach into
/// `lib/src/`.
int _codepointCount(String text) => text.runes.length;
