/// Web WASM implementation of dart_monty.
///
/// Import this library to use the WASM backend directly:
/// ```dart
/// import 'package:dart_monty/dart_monty_wasm.dart';
///
/// final monty = MontyWasm();
/// ```
library;

export 'src/wasm/monty_wasm.dart';
export 'src/wasm/wasm_bindings.dart';
export 'src/wasm/wasm_bindings_js_stub.dart'
    if (dart.library.js_interop) 'src/wasm/wasm_bindings_js.dart';
export 'src/wasm/wasm_core_bindings.dart';
