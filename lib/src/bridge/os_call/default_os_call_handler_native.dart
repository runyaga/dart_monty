import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';

/// Creates a default OsCallHandler backed by dart:io.
///
/// Handles filesystem (pathlib), environment (os.getenv/os.environ),
/// and datetime (date.today/datetime.now) operations.
OsCallHandler createDefaultOsCallHandler() {
  return (MontyOsCall call) => Future.value(_handleCall(call));
}

Object? _handleCall(MontyOsCall call) {
  final op = call.operationName;
  if (op.startsWith('Path.')) {
    return _handlePathOp(op, call.arguments, call.kwargs);
  }
  if (op.startsWith('os.')) {
    return _handleEnvOp(op, call.arguments);
  }
  if (op.startsWith('date.') || op.startsWith('datetime.')) {
    return _handleDateTimeOp(op);
  }
  throw UnsupportedError('Unsupported OS operation: $op');
}

Object? _handlePathOp(
  String op,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) => switch (op) {
  'Path.exists' =>
    FileSystemEntity.typeSync(_extractPath(args.first)) !=
        FileSystemEntityType.notFound,
  'Path.is_file' =>
    FileSystemEntity.typeSync(_extractPath(args.first)) ==
        FileSystemEntityType.file,
  'Path.is_dir' =>
    FileSystemEntity.typeSync(_extractPath(args.first)) ==
        FileSystemEntityType.directory,
  'Path.is_symlink' =>
    FileSystemEntity.typeSync(
          _extractPath(args.first),
          followLinks: false,
        ) ==
        FileSystemEntityType.link,
  'Path.read_text' => File(_extractPath(args.first)).readAsStringSync(),
  'Path.read_bytes' => File(
    _extractPath(args.first),
  ).readAsBytesSync().toList(),
  'Path.write_text' => _writeText(args),
  'Path.write_bytes' => _writeBytes(args),
  'Path.mkdir' => _mkdir(args, kwargs),
  'Path.unlink' => _unlink(args),
  'Path.rmdir' => _rmdir(args),
  'Path.rename' => _rename(args),
  'Path.iterdir' => Directory(
    _extractPath(args.first),
  ).listSync().map((e) => e.path).toList(),
  'Path.resolve' => File(_extractPath(args.first)).resolveSymbolicLinksSync(),
  'Path.absolute' => File(_extractPath(args.first)).absolute.path,
  _ => throw UnsupportedError('Unsupported path operation: $op'),
};

Object? _unlink(List<MontyValue> args) {
  File(_extractPath(args.first)).deleteSync();

  return null;
}

Object? _rmdir(List<MontyValue> args) {
  Directory(_extractPath(args.first)).deleteSync();

  return null;
}

int _writeText(List<MontyValue> args) {
  final path = _extractPath(args.first);
  final content = _extractPath(args[1]);
  File(path).writeAsStringSync(content);

  return content.length;
}

int _writeBytes(List<MontyValue> args) {
  final path = _extractPath(args.first);
  final bytes = (args[1].dartValue! as List).cast<int>();
  File(path).writeAsBytesSync(bytes);

  return bytes.length;
}

Object? _mkdir(List<MontyValue> args, Map<String, MontyValue>? kwargs) {
  final path = _extractPath(args.first);
  final parents = kwargs?['parents']?.dartValue as bool? ?? false;
  final existOk = kwargs?['exist_ok']?.dartValue as bool? ?? false;
  final dir = Directory(path);
  if (existOk && dir.existsSync()) return null;
  dir.createSync(recursive: parents);

  return null;
}

String _rename(List<MontyValue> args) {
  final oldPath = _extractPath(args.first);
  final newPath = _extractPath(args[1]);
  File(oldPath).renameSync(newPath);

  return newPath;
}

Object? _handleEnvOp(String op, List<MontyValue> args) => switch (op) {
  'os.getenv' =>
    Platform.environment[_extractPath(args.first)] ??
        (args.length > 1 ? args[1].dartValue : null),
  'os.environ' => Platform.environment,
  _ => throw UnsupportedError('Unsupported env operation: $op'),
};

Object? _handleDateTimeOp(String op) {
  final now = DateTime.now();

  return switch (op) {
    'date.today' => {
      '__type': 'date',
      'year': now.year,
      'month': now.month,
      'day': now.day,
    },
    'datetime.now' => {
      '__type': 'datetime',
      'year': now.year,
      'month': now.month,
      'day': now.day,
      'hour': now.hour,
      'minute': now.minute,
      'second': now.second,
      'microsecond': now.microsecond,
      'offset_seconds': now.timeZoneOffset.inSeconds,
      'timezone_name': now.timeZoneName,
    },
    _ => throw UnsupportedError('Unsupported datetime operation: $op'),
  };
}

/// Extracts a string path from a [MontyValue] argument.
///
/// Handles [MontyString] and [MontyPath] values.
String _extractPath(MontyValue arg) => switch (arg) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
