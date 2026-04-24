import 'package:dart_monty/src/web/ensure_initialized_stub.dart'
    if (dart.library.js_interop) 'package:dart_monty/src/web/ensure_initialized_web.dart'
    as platform;

/// Public entry point for Monty platform initialization.
///
/// On Flutter Web, `ensureInitialized()` dynamically injects the
/// `dart_monty_core` JS bridge script into `document.head` and awaits
/// its load. Call this once before constructing any `Monty`, `MontyRepl`,
/// or `MontyRuntime` on web — typically in `main()` after
/// `WidgetsFlutterBinding.ensureInitialized()` and before `runApp`.
///
/// On native targets (Dart VM, Flutter desktop/mobile), the call is a
/// no-op — Monty uses FFI there and needs no bridge.
///
/// Safe to call multiple times: subsequent calls are no-ops once the
/// bridge is loaded.
///
/// The bridge script lives in the `dart_monty_core` package's assets.
/// Flutter consumers must list `- package: dart_monty_core` under
/// `flutter.assets` in their own pubspec so the asset bundler serves
/// the file at `packages/dart_monty_core/assets/...`.
abstract final class DartMonty {
  /// Loads the Monty JS bridge for Flutter Web; no-op elsewhere.
  static Future<void> ensureInitialized() => platform.ensureInitialized();
}
