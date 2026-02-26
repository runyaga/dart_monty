/// Web plugin registration example.
///
/// `dart_monty_web` registers itself automatically via Flutter's federated
/// plugin system (`flutter_web_plugins`). Import `dart_monty` in your app —
/// no direct usage of this package is needed.
///
/// On web, the backend delegates to `MontyWasm` which runs Python in a
/// Web Worker via `@pydantic/monty` compiled to WASM.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final monty = MontyPlatform.instance;
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// ```
library;

void main() {
  // This package registers itself automatically via Flutter's federated
  // plugin system. See the dart_monty package for usage examples.
  assert(true, 'dart_monty_web registered');
}
