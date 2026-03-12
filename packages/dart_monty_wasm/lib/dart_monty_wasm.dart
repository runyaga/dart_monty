/// Web WASM implementation of dart_monty.
library;

export 'src/monty_wasm.dart';
export 'src/wasm_bindings.dart';
export 'src/wasm_bindings_js_stub.dart'
    if (dart.library.js_interop) 'src/wasm_bindings_js.dart';
export 'src/wasm_core_bindings.dart';
