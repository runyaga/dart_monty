/// High-level bridge layer for dart_monty.
///
/// Provides host function infrastructure, the default bridge implementation,
/// event loop support, and a plugin system for modular host function bundles.
library;

export 'src/attach_context.dart' show AttachContext;
export 'src/bridge_event.dart';
export 'src/bridge_logger.dart';
export 'src/execution_handle.dart';
export 'src/extension_coordinator.dart';
export 'src/extensions/default_extensions.dart';
export 'src/extensions/event_loop_extension.dart';
export 'src/extensions/message_bus_extension.dart';
export 'src/extensions/sandbox_extension.dart';
export 'src/extensions/template_extension.dart';
export 'src/function_surface.dart';
export 'src/host_context.dart';
export 'src/host_dispatch.dart' show MontyInterceptor;
export 'src/host_function.dart';
export 'src/host_args.dart';
export 'src/host_function_schema.dart';
export 'src/host_param.dart';
export 'src/host_param_type.dart';
export 'src/introspection_functions.dart';
export 'src/monty_backend_kind.dart';
export 'src/monty_bridge.dart';
export 'src/monty_extension.dart';
export 'src/monty_runtime.dart';
export 'src/os_call/decorator_handlers.dart';
export 'src/os_call/default_os_handler.dart';
export 'src/os_call/fs_handlers.dart';
export 'src/os_call/os_call_exception.dart';
export 'src/os_call/os_handlers.dart';
export 'src/os_call/path_op.dart';
export 'src/os_call/platform_handlers.dart';
export 'src/os_call/sandboxed_fs_handler_stub.dart'
    if (dart.library.io) 'src/os_call/sandboxed_fs_handler.dart';
export 'src/param_render_hint.dart';
export 'src/platform_bridge.dart';
export 'src/stateful_extension.dart';
export 'src/struct_log_bridge_logger.dart';
