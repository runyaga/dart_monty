// ignore_for_file: newline-before-return
import 'package:dart_monty/src/os_call/fs_handlers.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';

/// Default [OsHandler] on web platforms.
///
/// Composes:
/// - `Path.*` → [memoryFsHandler] (in-memory VFS)
///
/// No `os.*` environment access on web (no `dart:io`), and no clock routing:
/// every other call is declined, so the worker answers with its own default.
OsHandler defaultOsHandler() {
  return composeOsHandlers({'Path.': memoryFsHandler()});
}
