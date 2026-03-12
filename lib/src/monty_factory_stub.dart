import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Stub factory for unsupported platforms.
///
/// This is the fallback when neither `dart.library.ffi` nor
/// `dart.library.js_interop` is available.
MontyPlatform createPlatformMonty() =>
    throw UnsupportedError('No Monty backend available for this platform');
