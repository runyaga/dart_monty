import 'package:dart_monty/src/repl/repl_bindings.dart';
import 'package:dart_monty/src/repl/wasm_repl_bindings.dart';
import 'package:dart_monty/src/wasm/wasm_bindings_js.dart';

/// Creates REPL bindings using the WASM web backend.
ReplBindings createReplBindings() =>
    WasmReplBindings(bindings: WasmBindingsJs());
