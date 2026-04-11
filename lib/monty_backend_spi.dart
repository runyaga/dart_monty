/// Service Provider Interface for dart_monty platform backends.
///
/// This library exports types needed **only** by backend implementers —
/// not by application code.
///
/// Application code should import `dart_monty.dart` instead.
///
/// Backend authors: extend BaseMontyPlatform and implement
/// MontyCoreBindings to create a new platform backend.
library;

export 'src/platform/base_monty_platform.dart';
export 'src/platform/bridge_logger.dart';
export 'src/platform/core_bindings.dart';
export 'src/platform/monty_future_capable.dart';
export 'src/platform/monty_platform.dart';
export 'src/platform/monty_progress.dart';
export 'src/platform/monty_session.dart';
export 'src/platform/monty_snapshot_capable.dart';
export 'src/platform/monty_state_mixin.dart';
