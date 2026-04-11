// ignore_for_file: avoid-unsafe-collection-methods, avoid-non-null-assertion
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:file/file.dart';

/// Handles `Path.*` OS calls using any [FileSystem] implementation.
///
/// Works with both `LocalFileSystem` (native) and `MemoryFileSystem` (web/test).
/// This is the shared implementation behind platform-specific defaults.
///
/// Use `defaultSandboxOs` for the platform-appropriate default,
/// or construct directly with a custom [FileSystem]:
///
/// ```dart
/// final provider = FileSystemOsProvider(MemoryFileSystem());
/// ```
class FileSystemOsProvider extends OsProvider {
  /// Creates a provider backed by the given [fileSystem].
  const FileSystemOsProvider(this._fs) : super.base();

  final FileSystem _fs;

  /// The underlying filesystem (for Dart-side access, e.g. pre-populating VFS).
  FileSystem get fileSystem => _fs;

  @override
  Future<Object?> resolve(MontyOsCall call) => Future.value(_handleSync(call));

  Object? _handleSync(MontyOsCall call) {
    final op = call.operationName;
    final args = call.arguments;
    final kwargs = call.kwargs;

    return switch (op) {
      'Path.exists' => _exists(args),
      'Path.is_file' => _isFile(args),
      'Path.is_dir' => _isDir(args),
      'Path.is_symlink' => _isSymlink(args),
      'Path.read_text' => _readText(args),
      'Path.read_bytes' => _readBytes(args),
      'Path.write_text' => _writeText(args),
      'Path.write_bytes' => _writeBytes(args),
      'Path.mkdir' => _mkdir(args, kwargs),
      'Path.unlink' => _unlink(args),
      'Path.rmdir' => _rmdir(args),
      'Path.rename' => _rename(args),
      'Path.iterdir' => _iterdir(args),
      'Path.resolve' => _resolve(args),
      'Path.absolute' => _absolute(args),
      _ => throw UnsupportedError('Unsupported path operation: $op'),
    };
  }

  bool _exists(List<MontyValue> args) {
    final path = _str(args.first);

    return _fs.typeSync(path) != FileSystemEntityType.notFound;
  }

  bool _isFile(List<MontyValue> args) =>
      _fs.typeSync(_str(args.first)) == FileSystemEntityType.file;

  bool _isDir(List<MontyValue> args) =>
      _fs.typeSync(_str(args.first)) == FileSystemEntityType.directory;

  bool _isSymlink(List<MontyValue> args) =>
      _fs.typeSync(_str(args.first), followLinks: false) ==
      FileSystemEntityType.link;

  String _readText(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(path);
    if (!file.existsSync()) {
      throw OsCallFileNotFoundError('Path.read_text', 'No such file: $path');
    }

    return file.readAsStringSync();
  }

  List<int> _readBytes(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(path);
    if (!file.existsSync()) {
      throw OsCallFileNotFoundError('Path.read_bytes', 'No such file: $path');
    }

    return file.readAsBytesSync().toList();
  }

  int _writeText(List<MontyValue> args) {
    final path = _str(args.first);
    final content = _str(args[1]);
    _fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);

    return content.length;
  }

  int _writeBytes(List<MontyValue> args) {
    final path = _str(args.first);
    final bytes = (args[1].dartValue! as List).cast<int>();
    _fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);

    return bytes.length;
  }

  Object? _mkdir(List<MontyValue> args, Map<String, MontyValue>? kwargs) {
    final path = _str(args.first);
    final parents = kwargs?['parents']?.dartValue as bool? ?? false;
    final existOk = kwargs?['exist_ok']?.dartValue as bool? ?? false;
    final dir = _fs.directory(path);
    final exists = dir.existsSync();
    if (existOk && exists) return null;
    if (!parents && exists) {
      throw OsCallException('Path.mkdir', 'Directory exists: $path');
    }
    dir.createSync(recursive: parents);

    return null;
  }

  Object? _unlink(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(path);
    if (!file.existsSync()) {
      throw OsCallFileNotFoundError('Path.unlink', 'No such file: $path');
    }
    file.deleteSync();

    return null;
  }

  Object? _rmdir(List<MontyValue> args) {
    final path = _str(args.first);
    final dir = _fs.directory(path);
    if (!dir.existsSync()) {
      throw OsCallFileNotFoundError('Path.rmdir', 'No such directory: $path');
    }
    dir.deleteSync();

    return null;
  }

  String _rename(List<MontyValue> args) {
    final oldPath = _str(args.first);
    final newPath = _str(args[1]);
    _fs.file(oldPath).renameSync(newPath);

    return newPath;
  }

  List<MontyPath> _iterdir(List<MontyValue> args) {
    final path = _str(args.first);
    final dir = _fs.directory(path);
    if (!dir.existsSync()) {
      throw OsCallFileNotFoundError(
        'Path.iterdir',
        'No such directory: $path',
      );
    }

    return dir.listSync().map((e) => MontyPath(e.path)).toList();
  }

  String _resolve(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(_fs.path.join(_fs.currentDirectory.path, path));

    // Resolve symlinks if the target exists.
    if (file.existsSync()) {
      return file.resolveSymbolicLinksSync();
    }

    // Non-existent: return the absolute normalized path.
    return _fs.path.normalize(_fs.path.absolute(path));
  }

  String _absolute(List<MontyValue> args) {
    final path = _str(args.first);

    return _fs.path.normalize(_fs.path.absolute(path));
  }
}

String _str(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
