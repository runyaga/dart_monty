import 'package:dart_monty/src/ffi/monty_ffi.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';

/// Creates a Monty interpreter using the native FFI backend.
///
/// Selected at compile time via conditional import when `dart.library.ffi`
/// is available (desktop, server, mobile).
MontyPlatform createPlatformMonty() => MontyFfi();
