/// Platform interface for dart_monty.
///
/// Defines the shared API contract and domain types used by all
/// dart_monty packages. **Most users should import `dart_monty`
/// instead**, which re-exports everything from this library plus
/// the `Monty` convenience class.
///
/// ## Key Types
///
/// | Category | Types |
/// |----------|-------|
/// | **Core** | `MontyPlatform`, `MontyResult`, `MontyException` |
/// | **Execution** | `MontyProgress`, `MontyPending`, `MontyComplete` |
/// | **Errors** | `MontyError`, `MontyScriptError`, `MontyCancelledError` |
/// | **Config** | `MontyLimits`, `MontyResourceUsage` |
/// | **Sessions** | `MontySession`, `MontyCancelToken` |
///
/// ## For Backend Implementers
///
/// Import `monty_backend_spi.dart` for `BaseMontyPlatform` and
/// `MontyCoreBindings`.
library;

export 'src/bridge_logger.dart';
export 'src/monty_cancel_registry.dart';
export 'src/monty_cancel_token.dart';
export 'src/monty_error.dart';
export 'src/monty_exception.dart';
export 'src/monty_future_capable.dart';
export 'src/monty_limits.dart';
export 'src/monty_platform.dart';
export 'src/monty_progress.dart';
export 'src/monty_resource_usage.dart';
export 'src/monty_result.dart';
export 'src/monty_session.dart';
export 'src/monty_snapshot_capable.dart';
export 'src/monty_stack_frame.dart';
