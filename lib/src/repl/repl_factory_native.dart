import 'package:dart_monty/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty/src/repl/ffi_repl_bindings.dart';
import 'package:dart_monty/src/repl/repl_bindings.dart';

/// Creates REPL bindings using the native FFI backend.
ReplBindings createReplBindings() =>
    FfiReplBindings(bindings: NativeBindingsFfi());
