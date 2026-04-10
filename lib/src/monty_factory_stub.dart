import 'package:dart_monty/src/platform/monty_platform.dart';

/// Stub factory for unsupported platforms.
///
/// This is the fallback when neither `dart.library.ffi` nor
/// `dart.library.js_interop` is available.
MontyPlatform createPlatformMonty() =>
    throw UnsupportedError('No Monty backend available for this platform');
