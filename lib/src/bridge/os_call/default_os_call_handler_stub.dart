import 'package:dart_monty/src/bridge/os_call/os_call_handler.dart';
import 'package:dart_monty/src/bridge/os_call/router_os_call_handler.dart';

/// Creates a stub [OsCallHandler] for unsupported platforms.
///
/// Returns an empty [RouterOsCallHandler] that throws [UnsupportedError]
/// for all operations.
OsCallHandler createDefaultOsCallHandler() => RouterOsCallHandler({});
