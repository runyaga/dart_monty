/// Native (macOS, Linux, Windows, iOS, Android) implementation of dart_monty.
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_ffi/ffi_backend_spi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// Re-export from dart_monty_ffi for backward compatibility.
export 'package:dart_monty_ffi/dart_monty_ffi.dart' show MontyNative;
export 'package:dart_monty_ffi/ffi_backend_spi.dart'
    show NativeIsolateBindings, NativeIsolateBindingsImpl;

/// Native implementation of dart_monty.
class DartMontyNative {
  /// Registers this plugin as the platform implementation.
  static void registerWith() {
    // Flutter's federated plugin registration requires the global singleton.
    // ignore: deprecated_member_use
    MontyPlatform.instance = MontyNative(bindings: NativeIsolateBindingsImpl());
  }
}
