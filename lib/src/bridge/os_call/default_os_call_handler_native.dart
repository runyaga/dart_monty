import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';

/// Creates a default OsCallHandler backed by dart:io.
///
/// Handles filesystem (pathlib), environment (os.getenv/os.environ),
/// and datetime (date.today/datetime.now) operations.
OsCallHandler createDefaultOsCallHandler() {
  return (MontyOsCall call) async {
    final args = call.arguments;
    switch (call.operationName) {
      // -- Path operations --
      case 'Path.exists':
        return FileSystemEntity.typeSync(_extractPath(args.first)) !=
            FileSystemEntityType.notFound;
      case 'Path.is_file':
        return FileSystemEntity.typeSync(_extractPath(args.first)) ==
            FileSystemEntityType.file;
      case 'Path.is_dir':
        return FileSystemEntity.typeSync(_extractPath(args.first)) ==
            FileSystemEntityType.directory;
      case 'Path.is_symlink':
        return FileSystemEntity.typeSync(
              _extractPath(args.first),
              followLinks: false,
            ) ==
            FileSystemEntityType.link;
      case 'Path.read_text':
        return File(_extractPath(args.first)).readAsStringSync();
      case 'Path.read_bytes':
        return File(_extractPath(args.first)).readAsBytesSync().toList();
      case 'Path.write_text':
        final path = _extractPath(args[0]);
        final content = _extractPath(args[1]);
        File(path).writeAsStringSync(content);
        return content.length;
      case 'Path.write_bytes':
        final path = _extractPath(args[0]);
        final bytes = (args[1].dartValue! as List).cast<int>();
        File(path).writeAsBytesSync(bytes);
        return bytes.length;
      case 'Path.mkdir':
        final path = _extractPath(args.first);
        final parents = call.kwargs?['parents']?.dartValue as bool? ?? false;
        final existOk = call.kwargs?['exist_ok']?.dartValue as bool? ?? false;
        final dir = Directory(path);
        if (existOk && dir.existsSync()) return null;
        dir.createSync(recursive: parents);
        return null;
      case 'Path.unlink':
        File(_extractPath(args.first)).deleteSync();
        return null;
      case 'Path.rmdir':
        Directory(_extractPath(args.first)).deleteSync();
        return null;
      case 'Path.rename':
        final oldPath = _extractPath(args[0]);
        final newPath = _extractPath(args[1]);
        File(oldPath).renameSync(newPath);
        return newPath;
      case 'Path.iterdir':
        return Directory(
          _extractPath(args.first),
        ).listSync().map((e) => e.path).toList();
      case 'Path.resolve':
        return File(_extractPath(args.first)).resolveSymbolicLinksSync();
      case 'Path.absolute':
        return File(_extractPath(args.first)).absolute.path;

      // -- Environment --
      case 'os.getenv':
        final key = _extractPath(args.first);
        final defaultValue = args.length > 1 ? args[1].dartValue : null;
        return Platform.environment[key] ?? defaultValue;
      case 'os.environ':
        return Platform.environment;

      // -- DateTime --
      case 'date.today':
        final now = DateTime.now();
        return {
          '__type': 'date',
          'year': now.year,
          'month': now.month,
          'day': now.day,
        };
      case 'datetime.now':
        final now = DateTime.now();
        return {
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
        };

      default:
        throw UnsupportedError(
          'Unsupported OS operation: ${call.operationName}',
        );
    }
  };
}

/// Extracts a string path from a [MontyValue] argument.
///
/// Handles [MontyString] and [MontyPath] values.
String _extractPath(MontyValue arg) => switch (arg) {
  MontyString(:final value) => value,
  MontyPath(:final value) => value,
  _ => throw ArgumentError('Expected string or path, got: $arg'),
};
