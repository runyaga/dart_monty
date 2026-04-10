import 'package:dart_monty_bridge/src/bridge/default_monty_bridge.dart';

/// Stub — throws on platforms that support neither dart:io nor dart:js_interop.
OsCallHandler createDefaultOsCallHandler() {
  return (_) => throw UnsupportedError(
        'OsCallHandler not available on this platform',
      );
}
