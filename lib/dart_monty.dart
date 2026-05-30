/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
/// import 'package:dart_monty_core/dart_monty_core.dart';
///
/// final result = await Monty.exec('2 + 2');
/// print(result.value); // MontyInt(4)
/// ```
library;

// Execution engine — provided by dart_monty_core. dart_monty reuses core's
// OsCallException (carrying `pythonExceptionType`) rather than a parallel
// hierarchy, so handlers throw one type and core delivers the typed exception.
export 'package:dart_monty_core/dart_monty_core.dart';

// dart_monty bridge/plugin layer
export 'src/runtime/runtime.dart';
export 'src/runtime/runtime_ref.dart';
export 'src/runtime/value_x.dart';
export 'src/web/ensure_initialized.dart' show DartMonty;
