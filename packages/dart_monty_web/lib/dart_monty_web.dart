/// Web registration shim for the dart_monty federated plugin.
///
/// Registers [MontyWasm] as the [MontyPlatform] instance when running
/// in a browser. This class contains no logic — all execution is handled
/// by [MontyWasm] directly.
///
/// This package is not intended for direct use — import `dart_monty` instead.
library;

import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web registration shim for the dart_monty federated plugin.
///
/// Registers [MontyWasm] as the default [MontyPlatform] instance.
/// This class contains no logic — all execution is handled by [MontyWasm].
class DartMontyWeb {
  /// Registers [MontyWasm] as the default [MontyPlatform] instance.
  static void registerWith(Registrar registrar) {
    MontyPlatform.instance = MontyWasm(bindings: WasmBindingsJs());
  }
}
