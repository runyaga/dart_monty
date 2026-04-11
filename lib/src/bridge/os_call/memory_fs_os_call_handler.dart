import 'package:dart_monty/src/bridge/os_call/file_system_os_call_handler.dart';
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
class MemoryFsOsCallHandler extends FileSystemOsCallHandler {
  /// Creates a handler backed by a fresh in-memory filesystem.
  MemoryFsOsCallHandler() : super(MemoryFileSystem());

  /// Pre-populates a file in the VFS from Dart.
  ///
  /// Creates intermediate directories as needed.
  void writeFile(String path, String content) {
    fileSystem.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  /// Pre-populates a binary file in the VFS from Dart.
  void writeFileBytes(String path, List<int> bytes) {
    fileSystem.file(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }

  /// Reads a file from the VFS (for Dart-side verification after execution).
  String readFile(String path) => fileSystem.file(path).readAsStringSync();

  /// Reads binary content from the VFS.
  List<int> readFileBytes(String path) =>
      fileSystem.file(path).readAsBytesSync().toList();

  /// Whether a path exists in the VFS.
  bool exists(String path) =>
      fileSystem.file(path).existsSync() ||
      fileSystem.directory(path).existsSync();
}
