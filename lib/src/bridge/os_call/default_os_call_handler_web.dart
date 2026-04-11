import 'package:dart_monty/src/bridge/os_call/memory_fs_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/router_os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/time_os_call_handler.dart';

/// Creates a default [OsCallHandler] for web platforms.
///
/// Returns a [RouterOsCallHandler] with:
/// - `Path.*` -> [MemoryFsOsCallHandler] (in-memory VFS)
/// - `date.*`, `datetime.*` -> [TimeOsCallHandler]
///
/// No `os.*` environment access on web (no `dart:io`). Any `os.getenv`
/// or `os.environ` call will resume Python with a `PermissionError`.
OsCallHandler createDefaultOsCallHandler() {
  final time = TimeOsCallHandler();

  return RouterOsCallHandler({
    'Path.': MemoryFsOsCallHandler(),
    'date.': time,
    'datetime.': time,
  });
}
