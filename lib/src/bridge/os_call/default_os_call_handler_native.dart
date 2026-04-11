import 'dart:io';

import 'package:dart_monty/src/bridge/os_call/env_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/file_system_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/router_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/time_os_call_handler.dart';
import 'package:file/local.dart';

/// Creates a default [OsCallHandler] backed by `dart:io`.
///
/// Returns a [RouterOsCallHandler] that composes:
/// - `Path.*` -> [FileSystemOsCallHandler] with [LocalFileSystem]
/// - `os.*` -> [EnvOsCallHandler] (full host environment)
/// - `date.*`, `datetime.*` -> [TimeOsCallHandler]
///
/// **Native:** Full read/write access to the host filesystem. For
/// restricted access, use `SandboxedNativeFsHandler` instead.
OsCallHandler createDefaultOsCallHandler() {
  final time = TimeOsCallHandler();

  return RouterOsCallHandler({
    'Path.': FileSystemOsCallHandler(const LocalFileSystem()),
    'os.': EnvOsCallHandler(Platform.environment),
    'date.': time,
    'datetime.': time,
  });
}
