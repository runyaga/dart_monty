/// Pure Dart bindings for the Monty sandboxed Python interpreter.
///
/// This is the main entry point for running sandboxed Python from Dart.
/// The backend (native FFI or browser WASM) is selected at compile time
/// via conditional imports — no Flutter required.
///
/// ## Quick Start
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
///
/// final monty = Monty();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
///
/// ## Key Types
///
/// - [Monty] — create an interpreter and run Python code
/// - [MontyResult] — the return value from [Monty.run]
/// - [MontyProgress], [MontyPending], [MontyComplete] — iterative execution
///   with external functions via [Monty.start] / [Monty.resume]
/// - [MontyError] — sealed error hierarchy for exhaustive error handling
/// - [MontyLimits] — resource constraints (time, memory, stack depth)
/// - [MontySession] — stateful sessions that persist Python globals
///
/// ## Related Packages
///
/// - **dart_monty_bridge** — high-level bridge with host function dispatch,
///   event streaming, and a plugin system. Install separately:
///   `dart pub add dart_monty_bridge`
library;

export 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
export 'src/monty.dart';
