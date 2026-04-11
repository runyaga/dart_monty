import 'package:dart_monty/src/bridge/os_call/os_provider.dart';

/// Creates a stub [OsProvider] for unsupported platforms.
///
/// Returns an empty composite provider that throws [UnsupportedError]
/// for all operations.
OsProvider defaultSandboxOs() => OsProvider.compose({});
