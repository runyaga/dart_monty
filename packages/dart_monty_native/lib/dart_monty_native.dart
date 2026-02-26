/// Native (macOS, Linux, Windows, iOS, Android) implementation of dart_monty.
library;

import 'package:dart_monty_native/src/monty_native.dart';
import 'package:dart_monty_native/src/native_isolate_bindings_impl.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

export 'src/monty_native.dart';
export 'src/native_isolate_bindings.dart';
export 'src/native_isolate_bindings_impl.dart';

/// Native implementation of dart_monty.
class DartMontyNative {
  /// Registers this plugin as the platform implementation.
  static void registerWith() {
    MontyPlatform.instance = MontyNative(
      bindings: NativeIsolateBindingsImpl(),
    );
  }
}
