/// Native FFI implementation of dart_monty.
///
/// Import this library to use the FFI backend directly:
/// ```dart
/// import 'package:dart_monty/dart_monty_ffi.dart';
///
/// final monty = MontyFfi();
/// ```
library;

export 'src/ffi/ffi_core_bindings.dart';
export 'src/ffi/monty_ffi.dart';
export 'src/ffi/monty_native.dart';
export 'src/ffi/native_bindings.dart';
export 'src/ffi/native_bindings_ffi.dart';
export 'src/ffi/native_isolate_bindings.dart';
export 'src/ffi/native_isolate_bindings_impl.dart';
