import 'package:dart_monty/src/runtime/backend_kind_stub.dart'
    if (dart.library.ffi) 'package:dart_monty/src/runtime/backend_kind_native.dart'
    if (dart.library.js_interop) 'package:dart_monty/src/runtime/backend_kind_web.dart'
    as platform;

/// Identifies the compile-time Monty execution backend.
enum MontyBackendKind {
  /// Uses native FFI on VM and Flutter native targets.
  ffi,

  /// Uses WASM on browser targets.
  wasm,
}

/// Returns the backend selected by conditional imports.
MontyBackendKind get currentBackendKind => platform.currentBackendKind;

/// Reports an extension that rejects the current backend before attachment.
class UnsupportedBackendError extends Error {
  /// Captures the extension and its accepted backends.
  UnsupportedBackendError({
    required this.extensionNamespace,
    required this.current,
    required this.supported,
  });

  /// Namespace of the offending extension.
  final String extensionNamespace;

  /// The backend currently running.
  final MontyBackendKind current;

  /// Backends the extension declares support for.
  final Set<MontyBackendKind> supported;

  @override
  String toString() =>
      'UnsupportedBackendError: extension "$extensionNamespace" supports '
      '${supported.map((b) => b.name).join(", ")} but this program is '
      'running on ${current.name}.';
}
