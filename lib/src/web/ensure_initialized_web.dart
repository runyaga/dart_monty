import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web implementation of `DartMonty.ensureInitialized()`.
///
/// Dynamically injects the `dart_monty_core` JS bridge into
/// `document.head`, awaits its load, and verifies
/// `window.DartMontyBridge` is defined.
///
/// The URL `assets/packages/dart_monty_core/lib/assets/...` is where
/// Flutter serves transitively-bundled package assets. Consumers do
/// NOT need to redeclare the three asset files under their own
/// `flutter.assets` — adding `dart_monty` to pubspec is enough.
Future<void> ensureInitialized() async {
  if (_isBridgeLoaded()) return;

  await _injectScript(
    'assets/packages/dart_monty_core/lib/assets/dart_monty_core_bridge.js',
  );

  if (!_isBridgeLoaded()) {
    throw StateError(
      'dart_monty: bridge script loaded but window.DartMontyBridge is '
      'not defined. Run `flutter pub upgrade` to refresh dart_monty_core '
      'and rebuild; if the error persists, file an issue.',
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
          'dart_monty: failed to load Monty bridge from $src. '
          'dart_monty_core should be pulled in transitively via dart_monty; '
          'check `flutter pub deps` to confirm it is resolved, and that no '
          'consumer-side flutter.assets block is stripping it.',
        ),
      );
    }.toJS;
  web.document.head!.appendChild(script);
  return completer.future;
}
