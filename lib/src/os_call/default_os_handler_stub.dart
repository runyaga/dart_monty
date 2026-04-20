import 'package:dart_monty/src/os_call/os_handlers.dart';

/// Stub [OsCallHandler] for unsupported platforms — empty composite.
OsCallHandler defaultOsHandler() => composeOsHandlers({});
