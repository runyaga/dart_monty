/// SPI for dart_monty_ffi backend internals.
///
/// Import this library only from sibling monorepo packages
/// (e.g. `dart_monty_native`). Application code should import
/// `package:dart_monty_ffi/dart_monty_ffi.dart` instead.
library;

export 'src/ffi_core_bindings.dart';
export 'src/native_bindings.dart';
export 'src/native_bindings_ffi.dart';
export 'src/native_isolate_bindings.dart';
export 'src/native_isolate_bindings_impl.dart';
