import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_wasm/dart_monty_wasm.dart';

/// Creates a Monty interpreter using the WASM backend.
///
/// Selected at compile time via conditional import when
/// `dart.library.js_interop` is available (browser).
MontyPlatform createPlatformMonty() => MontyWasm();
