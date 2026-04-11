import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';
import 'package:file/memory.dart';

/// Handles `Path.*` OS calls using an in-memory virtual filesystem.
///
/// Works on all platforms (FFI and WASM) since it has no `dart:io` dependency.
/// Files are ephemeral — they exist only for the lifetime of this handler.
///
/// Use [writeFile] and [readFile] from Dart to pre-populate the VFS before
/// execution or read results after execution.
///
/// ```dart
/// final vfs = MemoryFsOsCallHandler();
/// vfs.writeFile('/sandbox/config.json', '{"key": "value"}');
/// bridge.registerOsCallHandler(RouterOsCallHandler({
///   'Path.': vfs,
///   ...
/// }));
/// ```
class MemoryFsOsCallHandler extends OsCallHandler {
  /// Creates a handler backed by a fresh in-memory filesystem.
  MemoryFsOsCallHandler() : _fs = MemoryFileSystem();

  final MemoryFileSystem _fs;

  /// Pre-populates a file in the VFS from Dart.
  ///
  /// Creates intermediate directories as needed.
  void writeFile(String path, String content) {
    _fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Pre-populates a binary file in the VFS from Dart.
  void writeFileBytes(String path, List<int> bytes) {
    _fs.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  /// Reads a file from the VFS (for Dart-side verification after execution).
  String readFile(String path) => _fs.file(path).readAsStringSync();

  /// Reads binary content from the VFS.
  List<int> readFileBytes(String path) =>
      _fs.file(path).readAsBytesSync().toList();

  /// Whether a path exists in the VFS.
  bool exists(String path) =>
      _fs.file(path).existsSync() || _fs.directory(path).existsSync();

  @override
  Future<Object?> handle(MontyOsCall call) => Future.value(_handleSync(call));

  Object? _handleSync(MontyOsCall call) {
    final op = call.operationName;
    final args = call.arguments;
    final kwargs = call.kwargs;

    return switch (op) {
      'Path.exists' => _exists(args),
      'Path.is_file' => _isFile(args),
      'Path.is_dir' => _isDir(args),
      'Path.is_symlink' => false, // VFS doesn't support symlinks
      'Path.read_text' => _readText(args),
      'Path.read_bytes' => _readBytes(args),
      'Path.write_text' => _writeText(args),
      'Path.write_bytes' => _writeBytes(args),
      'Path.mkdir' => _mkdir(args, kwargs),
      'Path.unlink' => _unlink(args),
      'Path.rmdir' => _rmdir(args),
      'Path.rename' => _rename(args),
      'Path.iterdir' => _iterdir(args),
      'Path.resolve' => _str(args.first), // No symlinks to resolve
      'Path.absolute' => _str(args.first),
      _ => throw UnsupportedError('Unsupported path operation: $op'),
    };
  }

  bool _exists(List<MontyValue> args) {
    final path = _str(args.first);
    return _fs.file(path).existsSync() || _fs.directory(path).existsSync();
  }

  bool _isFile(List<MontyValue> args) =>
      _fs.file(_str(args.first)).existsSync();

  bool _isDir(List<MontyValue> args) =>
      _fs.directory(_str(args.first)).existsSync();

  String _readText(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(path);
    if (!file.existsSync()) {
      throw OsCallFileNotFoundError(
        'Path.read_text',
        'No such file: $path',
      );
    }
    return file.readAsStringSync();
  }

  List<int> _readBytes(List<MontyValue> args) {
    final path = _str(args.first);
    final file = _fs.file(path);
    if (!file.existsSync()) {
      throw OsCallFileNotFoundError(
        'Path.read_bytes',
        'No such file: $path',
      );
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
    if (existOk && dir.existsSync()) return null;
    if (!parents && dir.existsSync()) {
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
}

String _str(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
