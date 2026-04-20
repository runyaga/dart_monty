/// High-level bridge layer for dart_monty.
///
/// Provides host function infrastructure, the default bridge implementation,
/// event loop support, and a plugin system for modular host function bundles.
library;

export 'src/bridge/bridge.dart';
export 'src/bridge/event.dart';
export 'src/bridge/logger.dart';
export 'src/bridge/platform.dart';
export 'src/bridge/struct_log_logger.dart';
export 'src/extension/attach_context.dart' show AttachContext;
export 'src/extension/coordinator.dart';
export 'src/extension/extension.dart';
export 'src/extension/stateful.dart';
export 'src/extensions/defaults.dart';
export 'src/extensions/event_loop.dart';
export 'src/extensions/jinja_template.dart';
export 'src/extensions/message_bus.dart';
export 'src/extensions/sandbox.dart';
export 'src/host/args.dart';
export 'src/host/context.dart';
export 'src/host/dispatch.dart' show MontyInterceptor;
export 'src/host/function.dart';
export 'src/host/function_surface.dart';
export 'src/host/param.dart';
export 'src/host/param_type.dart';
export 'src/host/render_hint.dart';
export 'src/host/schema.dart';
export 'src/os_call/decorator_handlers.dart';
export 'src/os_call/default_os_handler.dart';
export 'src/os_call/fs_handlers.dart';
export 'src/os_call/os_call_exception.dart';
export 'src/os_call/os_handlers.dart';
export 'src/os_call/path_op.dart';
export 'src/os_call/platform_handlers.dart';
export 'src/os_call/sandboxed_fs_handler_stub.dart'
    if (dart.library.io) 'src/os_call/sandboxed_fs_handler.dart';
export 'src/runtime/backend_kind.dart';
export 'src/runtime/execution_handle.dart';
export 'src/runtime/runtime.dart';
export 'src/runtime/runtime_ref.dart';
export 'src/runtime/runtime_state.dart';
