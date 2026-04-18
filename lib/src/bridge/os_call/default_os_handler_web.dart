// ignore_for_file: newline-before-return
import 'package:dart_monty/src/bridge/os_call/fs_handlers.dart';
import 'package:dart_monty/src/bridge/os_call/os_handlers.dart';
import 'package:dart_monty/src/bridge/os_call/platform_handlers.dart';

/// Default [OsCallHandler] on web platforms.
///
/// Composes:
/// - `Path.*` → [memoryFsHandler] (in-memory VFS)
/// - `date.*`, `datetime.*` → [timeHandler]
///
/// No `os.*` environment access on web (no `dart:io`). Any `os.getenv` or
/// `os.environ` call resumes Python with a `PermissionError`.
OsCallHandler defaultOsHandler() {
  final time = timeHandler();
  return composeOsHandlers({
    'Path.': memoryFsHandler(),
    'date.': time,
    'datetime.': time,
  });
}
