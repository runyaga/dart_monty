import 'package:dart_monty/src/os_call/os_handlers.dart';

/// Stub [OsHandler] for unsupported platforms — empty composite.
OsHandler defaultOsHandler() => composeOsHandlers({});
