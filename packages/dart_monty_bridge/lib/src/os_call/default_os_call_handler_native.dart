import 'dart:io';

import 'package:dart_monty_bridge/src/bridge/default_monty_bridge.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

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
        return FileSystemEntity.typeSync(_unwrapString(args.first)) !=
            FileSystemEntityType.notFound;
      case 'Path.is_file':
        return FileSystemEntity.typeSync(_unwrapString(args.first)) ==
            FileSystemEntityType.file;
      case 'Path.is_dir':
        return FileSystemEntity.typeSync(_unwrapString(args.first)) ==
            FileSystemEntityType.directory;
      case 'Path.is_symlink':
        return FileSystemEntity.typeSync(
              _unwrapString(args.first),
              followLinks: false,
            ) ==
            FileSystemEntityType.link;
      case 'Path.read_text':
        return File(_unwrapString(args.first)).readAsStringSync();
      case 'Path.read_bytes':
        return File(_unwrapString(args.first)).readAsBytesSync().toList();
      case 'Path.write_text':
        final path = _unwrapString(args[0]);
        final content = _unwrapString(args[1]);
        File(path).writeAsStringSync(content);
        return content.length;
      case 'Path.write_bytes':
        final path = _unwrapString(args[0]);
        final bytes = (args[1]! as List).cast<int>();
        File(path).writeAsBytesSync(bytes);
        return bytes.length;
      case 'Path.mkdir':
        final path = _unwrapString(args.first);
        final parents = call.kwargs?['parents'] as bool? ?? false;
        final existOk = call.kwargs?['exist_ok'] as bool? ?? false;
        final dir = Directory(path);
        if (existOk && dir.existsSync()) return null;
        dir.createSync(recursive: parents);
        return null;
      case 'Path.unlink':
        File(_unwrapString(args.first)).deleteSync();
        return null;
      case 'Path.rmdir':
        Directory(_unwrapString(args.first)).deleteSync();
        return null;
      case 'Path.rename':
        final oldPath = _unwrapString(args[0]);
        final newPath = _unwrapString(args[1]);
        File(oldPath).renameSync(newPath);
        return newPath;
      case 'Path.iterdir':
        return Directory(_unwrapString(args.first))
            .listSync()
            .map((e) => e.path)
            .toList();
      case 'Path.resolve':
        return File(_unwrapString(args.first)).resolveSymbolicLinksSync();
      case 'Path.absolute':
        return File(_unwrapString(args.first)).absolute.path;

      // -- Environment --
      case 'os.getenv':
        final key = _unwrapString(args.first);
        final defaultValue = args.length > 1 ? args[1] : null;
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

/// Extracts a string value, unwrapping __type wrappers if present.
///
/// Handles both bare strings and typed wrappers like
/// `{"__type": "path", "value": "/foo"}`.
String _unwrapString(Object? value) {
  if (value is String) return value;
  if (value is Map<String, dynamic>) {
    final inner = value['value'];
    if (inner is String) return inner;
  }
  throw ArgumentError('Expected string or __type wrapper, got: $value');
}
