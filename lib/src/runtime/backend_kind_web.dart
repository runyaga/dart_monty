import 'package:dart_monty/src/runtime/backend_kind.dart';

/// Web/WASM resolution of [currentBackendKind]; see the default exports.
MontyBackendKind get currentBackendKind => MontyBackendKind.wasm;
