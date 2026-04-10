import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/wasm/monty_wasm.dart';

/// Creates a Monty interpreter using the WASM backend.
///
/// Selected at compile time via conditional import when
/// `dart.library.js_interop` is available (browser).
MontyPlatform createPlatformMonty() => MontyWasm();
