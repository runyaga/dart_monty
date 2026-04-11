import 'dart:io';

import 'package:dart_monty/src/bridge/os_call/env_os_provider.dart';
import 'package:dart_monty/src/bridge/os_call/fs_provider.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/bridge/os_call/time_os_provider.dart';
import 'package:file/local.dart';

/// Creates a default [OsProvider] backed by `dart:io`.
///
/// Returns a composite provider that composes:
/// - `Path.*` -> [FsProvider] with [LocalFileSystem]
/// - `os.*` -> [EnvOsProvider] (full host environment)
/// - `date.*`, `datetime.*` -> [TimeOsProvider]
///
/// **Native:** Full read/write access to the host filesystem. For
/// restricted access, use `SandboxedFsProvider` instead.
OsProvider defaultSandboxOs() {
  final time = TimeOsProvider();

  return OsProvider.compose({
    'Path.': const FsProvider(LocalFileSystem()),
    'os.': EnvOsProvider(Platform.environment),
    'date.': time,
    'datetime.': time,
  });
}
