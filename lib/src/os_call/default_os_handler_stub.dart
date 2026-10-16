import 'package:dart_monty/src/os_call/os_handlers.dart';

/// Stub [OsHandler] for unsupported platforms — declines every call.
OsHandler defaultOsHandler() => composeOsHandlers({});
