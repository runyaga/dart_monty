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

  String safeResolved(String op, String pythonPath) {
    final safe = safePath(op, pythonPath);
    final type = FileSystemEntity.typeSync(safe, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      final resolved = File(safe).resolveSymbolicLinksSync();
      if (resolved != rootExact && !resolved.startsWith(rootWithSep)) {
        throw OsCallException(
          'Symlink escapes sandbox: $pythonPath -> $resolved',
          pythonExceptionType: 'PermissionError',
        );
      }
      return resolved;
    }
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
              FileSystemEntity.typeSync(safePath(operation, p)) ==
              FileSystemEntityType.file,
          isDirectory: (p) =>
              FileSystemEntity.typeSync(safePath(operation, p)) ==
              FileSystemEntityType.directory,
          truncate: (p) {
            File(safePath(operation, p))
              ..parent.createSync(recursive: true)
              ..writeAsStringSync('');
          },
          createIfMissing: (p) {
            final f = File(safePath(operation, p));
            if (!f.existsSync()) {
              f.parent.createSync(recursive: true);
              f.createSync();
            }
          },
        );
      case PathOp.appendText:
        final safe = safePath(operation, osArgString(args.first));
        final content = osArgString(args[1]);
        File(safe)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content, mode: FileMode.append);
        return content.length;
      case PathOp.appendBytes:
        final safe = safePath(operation, osArgString(args.first));
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
        final safe = safePath(operation, osArgString(args.first));
        final content = osArgString(args[1]);
        final file = File(safe);
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(content);
        return content.length;
      case PathOp.writeBytes:
        final safe = safePath(operation, osArgString(args.first));
        final bytes = (args[1]! as List).cast<int>();
        final file = File(safe);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
        return bytes.length;
      case PathOp.mkdir:
        final safe = safePath(operation, osArgString(args.first));
        final parents = kwargs?['parents'] as bool? ?? false;
        final existOk = kwargs?['exist_ok'] as bool? ?? false;
        final dir = Directory(safe);
        if (existOk && dir.existsSync()) return null;
        dir.createSync(recursive: parents);
        return null;
      case PathOp.unlink:
        File(safeResolved(operation, osArgString(args.first))).deleteSync();
        return null;
      case PathOp.rmdir:
        Directory(safePath(operation, osArgString(args.first))).deleteSync();
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
