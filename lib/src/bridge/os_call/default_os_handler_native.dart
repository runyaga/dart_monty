// ignore_for_file: newline-before-return
import 'dart:io';

import 'package:dart_monty/src/bridge/os_call/fs_handlers.dart';
import 'package:dart_monty/src/bridge/os_call/os_handlers.dart';
import 'package:dart_monty/src/bridge/os_call/platform_handlers.dart';
import 'package:dart_monty/src/bridge/os_call/sandboxed_fs_handler.dart';
import 'package:file/local.dart';

/// Default [OsCallHandler] on native (`dart:io`) platforms.
///
/// Composes:
/// - `Path.*` → [fsHandler] with [LocalFileSystem]
/// - `os.*`   → [envHandler] with full host environment
/// - `date.*`, `datetime.*` → [timeHandler]
///
/// **Native:** Full read/write access to the host filesystem. For restricted
/// access, use [sandboxedFsHandler] instead.
OsCallHandler defaultOsHandler() {
  final time = timeHandler();
  return composeOsHandlers({
    'Path.': fsHandler(const LocalFileSystem()),
    'os.': envHandler(Platform.environment),
    'date.': time,
    'datetime.': time,
  });
}
