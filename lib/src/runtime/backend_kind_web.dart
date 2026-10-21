import 'package:dart_monty/src/runtime/backend_kind.dart';

/// Resolves [currentBackendKind] for web WASM builds.
MontyBackendKind get currentBackendKind => MontyBackendKind.wasm;
