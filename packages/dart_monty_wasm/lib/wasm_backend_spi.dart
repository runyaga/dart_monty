/// SPI for dart_monty_wasm backend internals.
///
/// Import this library only from sibling monorepo packages
/// (e.g. `dart_monty_web`). Application code should import
/// `package:dart_monty_wasm/dart_monty_wasm.dart` instead.
library;

export 'src/wasm_bindings.dart';
export 'src/wasm_bindings_js_stub.dart'
    if (dart.library.js_interop) 'src/wasm_bindings_js.dart';
export 'src/wasm_core_bindings.dart';
