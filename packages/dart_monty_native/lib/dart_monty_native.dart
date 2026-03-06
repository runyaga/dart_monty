/// Native (macOS, Linux, Windows, iOS, Android) implementation of dart_monty.
library;

import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

// Re-export from dart_monty_ffi for backward compatibility.
export 'package:dart_monty_ffi/src/monty_native.dart';
export 'package:dart_monty_ffi/src/native_isolate_bindings.dart';
export 'package:dart_monty_ffi/src/native_isolate_bindings_impl.dart';

/// Native implementation of dart_monty.
class DartMontyNative {
  /// Registers this plugin as the platform implementation.
  static void registerWith() {
    MontyPlatform.instance = MontyNative(
      bindings: NativeIsolateBindingsImpl(),
    );
  }
}
