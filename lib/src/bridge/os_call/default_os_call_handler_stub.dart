import 'package:dart_monty/src/bridge/bridge/default_monty_bridge.dart';

/// Stub — throws on platforms that support neither dart:io nor dart:js_interop.
OsCallHandler createDefaultOsCallHandler() {
  return (_) => throw UnsupportedError(
    'OsCallHandler not available on this platform',
  );
}
