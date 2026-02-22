/// Desktop plugin registration example.
///
/// `dart_monty_desktop` registers itself automatically via Flutter's
/// federated plugin system. Import `dart_monty` in your app:
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final monty = MontyPlatform.instance;
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// ```
library;
