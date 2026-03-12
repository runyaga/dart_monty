import 'package:dart_monty_ffi/dart_monty_ffi.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Creates a Monty interpreter using the native FFI backend.
///
/// Selected at compile time via conditional import when `dart.library.ffi`
/// is available (desktop, server, mobile).
MontyPlatform createPlatformMonty() => MontyFfi();
