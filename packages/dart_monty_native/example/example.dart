/// Native plugin registration example.
///
/// `dart_monty_native` registers itself automatically via Flutter's
/// `dartPluginClass` mechanism. Import `dart_monty` in your app — no direct
/// usage of this package is needed.
///
/// On native platforms, the backend runs the Monty interpreter in a
/// background Isolate to keep the UI thread responsive.
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
  assert(true, 'dart_monty_native registered');
}
