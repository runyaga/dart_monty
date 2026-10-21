import 'package:dart_monty/src/runtime/backend_kind.dart';

/// Resolves [currentBackendKind] for native FFI builds.
MontyBackendKind get currentBackendKind => MontyBackendKind.ffi;
