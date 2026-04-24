import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web implementation of `DartMonty.ensureInitialized()`.
///
/// Dynamically injects
/// `packages/dart_monty_core/assets/dart_monty_core_bridge.js` into
/// `document.head`, awaits its load, and verifies that
/// `window.DartMontyBridge` is defined. Raises [StateError] with a
/// pointer to the most likely misconfiguration if the bridge fails to
/// load or doesn't register after load.
Future<void> ensureInitialized() async {
  if (_isBridgeLoaded()) return;

  await _injectScript(
    'packages/dart_monty_core/assets/dart_monty_core_bridge.js',
  );

  if (!_isBridgeLoaded()) {
    throw StateError(
      'dart_monty: bridge script loaded but window.DartMontyBridge is not '
      'defined. Ensure your app lists "- package: dart_monty_core" under '
      'flutter.assets in pubspec.yaml and that dart_monty_core is in your '
      'dependencies.',
    );
  }
}

@JS('window.DartMontyBridge')
external JSAny? get _dartMontyBridge;

bool _isBridgeLoaded() => _dartMontyBridge != null;

Future<void> _injectScript(String src) {
  final completer = Completer<void>();
  final script = (web.document.createElement('script') as web.HTMLScriptElement)
    ..src = src
    ..onload = (web.Event _) {
      completer.complete();
    }.toJS
    ..onerror = (web.Event _) {
      completer.completeError(
        StateError(
          'dart_monty: failed to load Monty bridge from $src. Verify '
          '"- package: dart_monty_core" is listed under flutter.assets '
          'in pubspec.yaml and that the dart_monty_core package is in '
          'your dependencies.',
        ),
      );
    }.toJS;
  web.document.head!.appendChild(script);
  return completer.future;
}
