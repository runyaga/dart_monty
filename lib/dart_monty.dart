/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final result = await Monty.exec('2 + 2');
/// print(result.value); // MontyInt(4)
/// ```
///
/// For filesystem/environment access:
/// ```dart
/// final monty = Monty(os: OsProvider());
/// ```
library;

export 'src/bridge/agent_session.dart';
export 'src/bridge/os_call/os_call_exception.dart';
export 'src/bridge/os_call/os_provider.dart';
export 'src/monty.dart';
export 'src/platform/monty_error.dart';
export 'src/platform/monty_exception.dart';
export 'src/platform/monty_limits.dart';
export 'src/platform/monty_resource_usage.dart';
export 'src/platform/monty_result.dart';
export 'src/platform/monty_stack_frame.dart';
export 'src/platform/monty_state_mixin.dart';
export 'src/platform/monty_value.dart';
export 'src/repl/monty_repl.dart';
export 'src/repl/repl_platform.dart';
export 'src/repl/repl_session.dart';
