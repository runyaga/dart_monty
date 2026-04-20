/// High-level bridge layer for dart_monty.
///
/// Provides host function infrastructure, the default bridge implementation,
/// event loop support, and a plugin system for modular host function bundles.
library;

export 'src/bridge_event.dart';
export 'src/bridge_logger.dart';
export 'src/default_monty_bridge.dart';
export 'src/execution_handle.dart';
export 'src/host_context.dart';
export 'src/host_function.dart';
export 'src/host_function_schema.dart';
export 'src/host_param.dart';
export 'src/host_param_type.dart';
export 'src/introspection_functions.dart';
export 'src/monty_backend_kind.dart';
export 'src/monty_bridge.dart';
export 'src/monty_plugin.dart';
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
export 'src/host_dispatch.dart' show MontyInterceptor;
export 'src/plugin_host.dart' show PluginHost;
export 'src/plugin_registry.dart';
export 'src/plugins/default_plugins.dart';
export 'src/plugins/event_loop_plugin.dart';
export 'src/plugins/message_bus_plugin.dart';
export 'src/plugins/sandbox_plugin.dart';
export 'src/plugins/template_plugin.dart';
export 'src/stateful_plugin.dart';
export 'src/struct_log_bridge_logger.dart';
export 'src/tool_surface.dart';
