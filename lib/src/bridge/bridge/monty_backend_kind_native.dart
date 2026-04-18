import 'package:dart_monty/src/bridge/bridge/monty_backend_kind.dart';

/// Native-FFI resolution of [currentBackendKind]; see the default exports.
MontyBackendKind get currentBackendKind => MontyBackendKind.ffi;
