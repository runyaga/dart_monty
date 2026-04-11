import 'package:dart_monty/src/bridge/os_call/memory_fs_provider.dart';
import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/bridge/os_call/time_os_provider.dart';

/// Creates a default [OsProvider] for web platforms.
///
/// Returns a composite provider with:
/// - `Path.*` -> [MemoryFsProvider] (in-memory VFS)
/// - `date.*`, `datetime.*` -> [TimeOsProvider]
///
/// No `os.*` environment access on web (no `dart:io`). Any `os.getenv`
/// or `os.environ` call will resume Python with a `PermissionError`.
OsProvider defaultSandboxOs() {
  final time = TimeOsProvider();

  return OsProvider.compose({
    'Path.': MemoryFsProvider(),
    'date.': time,
    'datetime.': time,
  });
}
