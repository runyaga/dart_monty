/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final value = await Monty.withPool(
///   (monty) => monty.withSession((session) => session.feedRun('2 + 2')),
/// );
/// print(value); // MontyInt(4)
/// ```
library;

// Execution engine — provided by dart_monty_core. dart_monty reuses core's
// ExternalException (carrying `excType`) rather than a parallel hierarchy, so
// handlers throw one type and core delivers the typed exception.
export 'package:dart_monty_core/dart_monty_core.dart';

// dart_monty bridge/plugin layer
export 'src/runtime/runtime.dart' show MontyRuntime;
export 'src/runtime/runtime_ref.dart' show HostParentRef;
