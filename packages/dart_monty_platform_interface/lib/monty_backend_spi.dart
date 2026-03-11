/// Service Provider Interface for dart_monty platform backends.
///
/// This library exports types needed **only** by backend implementers
/// (dart_monty_ffi, dart_monty_wasm) — not by application code.
///
/// Application code should import `dart_monty_platform_interface.dart`
/// instead, which provides the public API (MontyPlatform, MontyResult,
/// MontyError, etc.) without leaking backend implementation details.
///
/// Backend authors: extend BaseMontyPlatform and implement
/// MontyCoreBindings to create a new platform backend.
library;

export 'src/base_monty_platform.dart';
export 'src/core_bindings.dart';
export 'src/monty_state_mixin.dart';
