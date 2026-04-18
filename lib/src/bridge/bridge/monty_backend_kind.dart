import 'package:dart_monty/src/bridge/bridge/monty_backend_kind_stub.dart'
    if (dart.library.ffi) 'package:dart_monty/src/bridge/bridge/monty_backend_kind_native.dart'
    if (dart.library.js_interop) 'package:dart_monty/src/bridge/bridge/monty_backend_kind_web.dart'
    as platform;

/// The Monty execution backend the current Dart program is compiled against.
///
/// Determined at compile time via conditional import (see
/// [currentBackendKind]).
enum MontyBackendKind {
  /// Native FFI backend — available when `dart.library.ffi` is present
  /// (Dart VM, Flutter desktop/mobile, server).
  ffi,

  /// WASM backend — available when `dart.library.js_interop` is present
  /// (browser).
  wasm,
}

/// The backend this compile unit runs against.
///
/// Resolved at compile time. `PluginRegistry.attachTo` compares each plugin's
/// `supportedBackends` against this value and throws
/// [UnsupportedBackendError] if a plugin declares it cannot run here.
MontyBackendKind get currentBackendKind => platform.currentBackendKind;

/// Thrown when a plugin's declared `supportedBackends` does not include the
/// current runtime backend.
///
/// Raised from `PluginRegistry.attachTo` before any script executes so the
/// failure is a clean configuration error rather than a mid-run crash.
class UnsupportedBackendError extends Error {
  /// Creates an [UnsupportedBackendError].
  UnsupportedBackendError({
    required this.pluginNamespace,
    required this.current,
    required this.supported,
  });

  /// Namespace of the offending plugin.
  final String pluginNamespace;

  /// The backend currently running.
  final MontyBackendKind current;

  /// Backends the plugin declares support for.
  final Set<MontyBackendKind> supported;

  @override
  String toString() =>
      'UnsupportedBackendError: plugin "$pluginNamespace" supports '
      '${supported.map((b) => b.name).join(", ")} but this program is '
      'running on ${current.name}.';
}
