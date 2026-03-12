/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// Backend is selected at compile time via conditional imports:
/// native FFI on desktop/server, WASM in browsers. No Flutter required.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final monty = Monty();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
library;

export 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
export 'src/monty.dart';
