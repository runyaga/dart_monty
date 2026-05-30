// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
// ignore_for_file: avoid-unnecessary-futures, newline-before-return
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/os_call/path_op.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show MontyBytes, MontyPath, OsCallException, OsCallHandler, resolveOpenCall;
import 'package:file/file.dart';
import 'package:file/memory.dart';

/// Handler for `Path.*` operations against any [FileSystem].
///
/// Works with both `LocalFileSystem` (native) and `MemoryFileSystem`
/// (web/test). Paths are not sandboxed — pass absolute paths from Python
/// through unchanged.
///
/// ```dart
/// final handler = fsHandler(MemoryFileSystem());
/// ```
OsCallHandler fsHandler(FileSystem fs) {
  return (operation, args, kwargs) async {
    switch (operation) {
      case PathOp.open:
        // Core owns the open() mode→effect mapping; supply this FileSystem's
        // primitives. The engine then drives reads/writes via the Path.* ops.
        final path = osArgString(args.first);
        final mode = args.length > 1 ? osArgString(args[1]) : 'r';
        return resolveOpenCall(
          path,
          mode,
          exists: (p) => fs.typeSync(p) == FileSystemEntityType.file,
          isDirectory: (p) => fs.typeSync(p) == FileSystemEntityType.directory,
          truncate: (p) => fs.file(p)
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(''),
          createIfMissing: (p) {
            final f = fs.file(p);
            if (!f.existsSync()) {
              f.parent.createSync(recursive: true);
              f.createSync();
            }
          },
        );
      case PathOp.exists:
        return fs.typeSync(osArgString(args.first)) !=
            FileSystemEntityType.notFound;
      case PathOp.isFile:
        return fs.typeSync(osArgString(args.first)) ==
            FileSystemEntityType.file;
      case PathOp.isDir:
        return fs.typeSync(osArgString(args.first)) ==
            FileSystemEntityType.directory;
      case PathOp.isSymlink:
        return fs.typeSync(osArgString(args.first), followLinks: false) ==
            FileSystemEntityType.link;
      case PathOp.readText:
        final path = osArgString(args.first);
        final file = fs.file(path);
        if (!file.existsSync()) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        return file.readAsStringSync();
      case PathOp.readBytes:
        final path = osArgString(args.first);
        final file = fs.file(path);
        if (!file.existsSync()) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        // Typed bytes (not a bare list) so binary `open(...,'rb').read()`
        // buffers correctly.
        return MontyBytes(file.readAsBytesSync());
      case PathOp.writeText:
        final path = osArgString(args.first);
        final content = osArgString(args[1]);
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content);
        return content.length;
      case PathOp.writeBytes:
        final path = osArgString(args.first);
        final bytes = (args[1]! as List).cast<int>();
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes);
        return bytes.length;
      case PathOp.appendText:
        final path = osArgString(args.first);
        final content = osArgString(args[1]);
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(content, mode: FileMode.append);
        return content.length;
      case PathOp.appendBytes:
        final path = osArgString(args.first);
        final bytes = (args[1]! as List).cast<int>();
        fs.file(path)
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(bytes, mode: FileMode.append);
        return bytes.length;
      case PathOp.mkdir:
        final path = osArgString(args.first);
        final parents = kwargs?['parents'] as bool? ?? false;
        final existOk = kwargs?['exist_ok'] as bool? ?? false;
        final dir = fs.directory(path);
        final exists = dir.existsSync();
        if (existOk && exists) return null;
        if (!parents && exists) {
          throw OsCallException(
            'Directory exists: $path',
            pythonExceptionType: 'FileExistsError',
          );
        }
        dir.createSync(recursive: parents);
        return null;
      case PathOp.unlink:
        final path = osArgString(args.first);
        final file = fs.file(path);
        if (!file.existsSync()) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        file.deleteSync();
        return null;
      case PathOp.rmdir:
        final path = osArgString(args.first);
        final dir = fs.directory(path);
        if (!dir.existsSync()) {
          throw OsCallException(
            'No such directory: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        dir.deleteSync();
        return null;
      case PathOp.rename:
        final oldPath = osArgString(args.first);
        final newPath = osArgString(args[1]);
        fs.file(oldPath).renameSync(newPath);
        return newPath;
      case PathOp.iterdir:
        final path = osArgString(args.first);
        final dir = fs.directory(path);
        if (!dir.existsSync()) {
          throw OsCallException(
            'No such directory: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        return dir.listSync().map((e) => MontyPath(e.path)).toList();
      case PathOp.resolve:
        final path = osArgString(args.first);
        final file = fs.file(fs.path.join(fs.currentDirectory.path, path));
        if (file.existsSync()) {
          return file.resolveSymbolicLinksSync();
        }
        return fs.path.normalize(fs.path.absolute(path));
      case PathOp.absolute:
        return fs.path.normalize(fs.path.absolute(osArgString(args.first)));
    }
    throw UnsupportedError('Unsupported path operation: $operation');
  };
}

/// Fresh in-memory VFS [OsCallHandler] — works on all platforms.
///
/// For tests or hosts that need to pre-populate or read back files, hold the
/// [MemoryFileSystem] yourself and pass it to [fsHandler]:
///
/// ```dart
/// final fs = MemoryFileSystem()
///   ..file('/sandbox/config.json').writeAsStringSync('{"k": 1}');
/// bridge.registerOs(composeOsHandlers({'Path.': fsHandler(fs), ...}));
/// ```
OsCallHandler memoryFsHandler() => fsHandler(MemoryFileSystem());
