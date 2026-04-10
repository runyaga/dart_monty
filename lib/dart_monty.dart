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

export 'src/monty.dart';
export 'src/platform/bridge_logger.dart';
export 'src/platform/monty_error.dart';
export 'src/platform/monty_exception.dart';
export 'src/platform/monty_future_capable.dart';
export 'src/platform/monty_limits.dart';
export 'src/platform/monty_platform.dart';
export 'src/platform/monty_progress.dart';
export 'src/platform/monty_resource_usage.dart';
export 'src/platform/monty_result.dart';
export 'src/platform/monty_session.dart';
export 'src/platform/monty_snapshot_capable.dart';
export 'src/platform/monty_stack_frame.dart';
export 'src/platform/monty_value.dart';
