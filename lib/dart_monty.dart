/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
/// import 'package:dart_monty_core/dart_monty_core.dart';
///
/// final monty = Monty();
/// final result = await monty.exec('2 + 2');
/// print(result.value); // MontyInt(4)
/// ```
library;

// Execution engine — provided by dart_monty_core.
// OsCallException is intentionally hidden: dart_monty keeps its own richer
// subclass hierarchy (OsCallPermissionError, OsCallFileNotFoundError).
export 'package:dart_monty_core/dart_monty_core.dart' hide OsCallException;

// dart_monty bridge/plugin layer
export 'src/bridge/bridge/monty_plugin.dart';
export 'src/bridge/event.dart';
export 'src/extension/extension.dart';
export 'src/extension/stateful.dart';
export 'src/host/context.dart';
export 'src/host/function.dart';
export 'src/host/schema.dart';
export 'src/os_call/os_call_exception.dart';
export 'src/os_call/os_handlers.dart';
export 'src/runtime/runtime.dart';
export 'src/runtime/runtime_ref.dart';
export 'src/runtime/value_x.dart';
