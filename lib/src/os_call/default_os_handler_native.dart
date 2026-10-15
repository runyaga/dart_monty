// ignore_for_file: newline-before-return
import 'dart:io';

import 'package:dart_monty/src/os_call/fs_handlers.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/os_call/platform_handlers.dart';
import 'package:dart_monty/src/os_call/sandboxed_fs_handler.dart';
import 'package:file/local.dart';

/// Default [OsHandler] on native (`dart:io`) platforms.
///
/// Composes:
/// - `Path.*` → [fsHandler] with [LocalFileSystem]
/// - `os.*`   → [envHandler] with full host environment
///
/// The clock is not routed here: under the worker's default `OsPolicy` it is
/// answered in the worker (upstream's `system` clock), and any `date.*`,
/// `datetime.*` or `time.*` call that does reach this handler is declined.
///
/// **Native:** Full read/write access to the host filesystem. For restricted
/// access, use [sandboxedFsHandler] instead.
OsHandler defaultOsHandler() {
  return composeOsHandlers({
    'Path.': fsHandler(const LocalFileSystem()),
    'os.': envHandler(Platform.environment),
  });
}
