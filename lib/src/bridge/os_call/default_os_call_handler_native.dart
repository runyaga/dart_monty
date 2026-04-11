import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/os_call/env_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/router_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/time_os_call_handler.dart';

/// Creates a default [OsCallHandler] backed by `dart:io`.
///
/// Returns a [RouterOsCallHandler] that composes:
/// - `Path.*` -> [DefaultNativePathHandler] (unrestricted filesystem)
/// - `os.*` -> [EnvOsCallHandler] (full host environment)
OsCallHandler createDefaultOsCallHandler() {
  final time = TimeOsCallHandler();

  return RouterOsCallHandler({
    'Path.': DefaultNativePathHandler(),
    'os.': EnvOsCallHandler(Platform.environment),
    'date.': time,
    'datetime.': time,
  });
}

/// Handles `Path.*` OS calls using unrestricted `dart:io`.
///
/// Provides the sandboxed Python code with full read/write access to the
/// host filesystem. For production use, prefer `SandboxedNativeFsHandler`
/// which restricts access to a chroot directory.
class DefaultNativePathHandler extends OsCallHandler {
  @override
  Future<Object?> handle(MontyOsCall call) => Future.value(
    _handlePathOp(call.operationName, call.arguments, call.kwargs),
  );
}

Object? _handlePathOp(
  String op,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) => switch (op) {
  'Path.exists' =>
    FileSystemEntity.typeSync(_str(args.first)) !=
        FileSystemEntityType.notFound,
  'Path.is_file' =>
    FileSystemEntity.typeSync(_str(args.first)) == FileSystemEntityType.file,
  'Path.is_dir' =>
    FileSystemEntity.typeSync(_str(args.first)) ==
        FileSystemEntityType.directory,
  'Path.is_symlink' =>
    FileSystemEntity.typeSync(_str(args.first), followLinks: false) ==
        FileSystemEntityType.link,
  'Path.read_text' => File(_str(args.first)).readAsStringSync(),
  'Path.read_bytes' => File(_str(args.first)).readAsBytesSync().toList(),
  'Path.write_text' => _writeText(args),
  'Path.write_bytes' => _writeBytes(args),
  'Path.mkdir' => _mkdir(args, kwargs),
  'Path.unlink' => _unlink(args),
  'Path.rmdir' => _rmdir(args),
  'Path.rename' => _rename(args),
  'Path.iterdir' => Directory(
    _str(args.first),
  ).listSync().map((e) => MontyPath(e.path)).toList(),
  'Path.resolve' => File(_str(args.first)).resolveSymbolicLinksSync(),
  'Path.absolute' => File(_str(args.first)).absolute.path,
  _ => throw UnsupportedError('Unsupported path operation: $op'),
};

Object? _unlink(List<MontyValue> args) {
  File(_str(args.first)).deleteSync();

  return null;
}

Object? _rmdir(List<MontyValue> args) {
  Directory(_str(args.first)).deleteSync();

  return null;
}

int _writeText(List<MontyValue> args) {
  final path = _str(args.first);
  final content = _str(args[1]);
  File(path).writeAsStringSync(content);

  return content.length;
}

int _writeBytes(List<MontyValue> args) {
  final path = _str(args.first);
  final bytes = (args[1].dartValue! as List).cast<int>();
  File(path).writeAsBytesSync(bytes);

  return bytes.length;
}

Object? _mkdir(List<MontyValue> args, Map<String, MontyValue>? kwargs) {
  final path = _str(args.first);
  final parents = kwargs?['parents']?.dartValue as bool? ?? false;
  final existOk = kwargs?['exist_ok']?.dartValue as bool? ?? false;
  final dir = Directory(path);
  if (existOk && dir.existsSync()) return null;
  dir.createSync(recursive: parents);

  return null;
}

String _rename(List<MontyValue> args) {
  final oldPath = _str(args.first);
  final newPath = _str(args[1]);
  File(oldPath).renameSync(newPath);

  return newPath;
}

String _str(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
