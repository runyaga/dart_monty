import 'dart:io';

import 'package:dart_monty/src/bridge/os_call/os_call_exception.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;

/// Handles `Path.*` OS calls against the real filesystem, restricted to
/// a `root` directory.
///
/// Every incoming path from Python is resolved to an absolute, normalized
/// path and checked against `root`. Paths that escape the sandbox (via
/// `../`, absolute paths outside root, or symlinks pointing outside) are
/// rejected with `OsCallPermissionError`.
///
/// ```dart
/// final tmp = Directory.systemTemp.createTempSync('monty_');
/// final provider = SandboxedFsProvider(root: tmp);
/// ```
class SandboxedFsProvider extends OsProvider {
  /// Creates a provider rooted at [root].
  ///
  /// [root] must exist. All Python file operations are restricted to
  /// paths inside this directory.
  factory SandboxedFsProvider({required Directory root}) {
    final resolved = root.resolveSymbolicLinksSync();

    return SandboxedFsProvider._(resolved);
  }

  SandboxedFsProvider._(this._rootExact)
    : _root = _rootExact.endsWith(Platform.pathSeparator)
          ? _rootExact
          : '$_rootExact${Platform.pathSeparator}',
      super.base();

  /// Normalized root path WITH trailing separator (for startsWith checks).
  final String _root;

  /// Normalized root path WITHOUT trailing separator (for == checks).
  final String _rootExact;

  @override
  Future<Object?> resolve(MontyOsCall call) => Future.value(_handleSync(call));

  @override
  Future<void> dispose() async {
    // We don't own the root directory — caller is responsible for cleanup.
  }

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
      'Path.absolute' => _safePath(op, _str(args.first)),
      _ => throw UnsupportedError('Unsupported path operation: $op'),
    };
  }

  /// Resolves a Python path to a safe absolute path inside the sandbox.
  ///
  /// The path from Python may be absolute (e.g., `/sandbox/foo`) or
  /// relative. We join it with [_rootExact], normalize, and verify it
  /// does not escape.
  String _safePath(String op, String pythonPath) {
    final joined = p.isAbsolute(pythonPath)
        ? p.normalize(pythonPath)
        : p.normalize(p.join(_rootExact, pythonPath));

    if (joined != _rootExact && !joined.startsWith(_root)) {
      throw OsCallPermissionError(op, 'Path escapes sandbox: $pythonPath');
    }

    return joined;
  }

  /// Like [_safePath] but also resolves symlinks and re-checks.
  String _safeResolved(String op, String pythonPath) {
    final safe = _safePath(op, pythonPath);
    // Only resolve symlinks if the target exists.
    final type = FileSystemEntity.typeSync(safe, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      final resolved = File(safe).resolveSymbolicLinksSync();
      if (resolved != _rootExact && !resolved.startsWith(_root)) {
        throw OsCallPermissionError(
          op,
          'Symlink escapes sandbox: $pythonPath -> $resolved',
        );
      }

      return resolved;
    }

    return safe;
  }

  bool _exists(List<MontyValue> args) {
    final safe = _safePath('Path.exists', _str(args.first));

    return FileSystemEntity.typeSync(safe) != FileSystemEntityType.notFound;
  }

  bool _isFile(List<MontyValue> args) {
    final safe = _safePath('Path.is_file', _str(args.first));

    return FileSystemEntity.typeSync(safe) == FileSystemEntityType.file;
  }

  bool _isDir(List<MontyValue> args) {
    final safe = _safePath('Path.is_dir', _str(args.first));

    return FileSystemEntity.typeSync(safe) == FileSystemEntityType.directory;
  }

  bool _isSymlink(List<MontyValue> args) {
    final safe = _safePath('Path.is_symlink', _str(args.first));

    return FileSystemEntity.typeSync(safe, followLinks: false) ==
        FileSystemEntityType.link;
  }

  String _readText(List<MontyValue> args) {
    final safe = _safeResolved('Path.read_text', _str(args.first));

    return File(safe).readAsStringSync();
  }

  List<int> _readBytes(List<MontyValue> args) {
    final safe = _safeResolved('Path.read_bytes', _str(args.first));

    return File(safe).readAsBytesSync().toList();
  }

  int _writeText(List<MontyValue> args) {
    final safe = _safePath('Path.write_text', _str(args.first));
    final content = _str(args[1]);
    final file = File(safe);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);

    return content.length;
  }

  int _writeBytes(List<MontyValue> args) {
    final safe = _safePath('Path.write_bytes', _str(args.first));
    final bytes = (args[1].dartValue! as List).cast<int>();
    final file = File(safe);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);

    return bytes.length;
  }

  Object? _mkdir(List<MontyValue> args, Map<String, MontyValue>? kwargs) {
    final safe = _safePath('Path.mkdir', _str(args.first));
    final parents = kwargs?['parents']?.dartValue as bool? ?? false;
    final existOk = kwargs?['exist_ok']?.dartValue as bool? ?? false;
    final dir = Directory(safe);
    if (existOk && dir.existsSync()) return null;
    dir.createSync(recursive: parents);

    return null;
  }

  Object? _unlink(List<MontyValue> args) {
    final safe = _safeResolved('Path.unlink', _str(args.first));
    File(safe).deleteSync();

    return null;
  }

  Object? _rmdir(List<MontyValue> args) {
    final safe = _safePath('Path.rmdir', _str(args.first));
    Directory(safe).deleteSync();

    return null;
  }

  String _rename(List<MontyValue> args) {
    final oldSafe = _safeResolved('Path.rename', _str(args.first));
    final newSafe = _safePath('Path.rename', _str(args[1]));
    File(oldSafe).renameSync(newSafe);

    return newSafe;
  }

  List<MontyPath> _iterdir(List<MontyValue> args) {
    final safe = _safePath('Path.iterdir', _str(args.first));

    return Directory(safe).listSync().map((e) => MontyPath(e.path)).toList();
  }

  String _resolve(List<MontyValue> args) =>
      _safeResolved('Path.resolve', _str(args.first));
}

String _str(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
