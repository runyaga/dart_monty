/// High-level bridge layer for dart_monty.
///
/// Provides host function infrastructure, the default bridge implementation,
/// event loop support, and a plugin system for modular host function bundles.
library;

export 'src/bridge/agent_session.dart';
export 'src/bridge/bridge/bridge_event.dart';
export 'src/bridge/bridge/bridge_middleware.dart';
export 'src/bridge/bridge/host_function.dart';
export 'src/bridge/bridge/host_function_schema.dart';
export 'src/bridge/bridge/host_param.dart';
export 'src/bridge/bridge/host_param_type.dart';
export 'src/bridge/bridge/monty_bridge.dart';
export 'src/bridge/bridge/monty_plugin.dart';
export 'src/bridge/bridge/plugin_registry.dart';
export 'src/bridge/bridge/struct_log_bridge_logger.dart';
export 'src/bridge/os_call/default_sandbox_os.dart';
export 'src/bridge/os_call/env_os_provider.dart';
export 'src/bridge/os_call/fs_provider.dart';
export 'src/bridge/os_call/memory_fs_provider.dart';
export 'src/bridge/os_call/os_call_exception.dart';
export 'src/bridge/os_call/os_provider.dart';
export 'src/bridge/os_call/overlay_fs_provider.dart';
export 'src/bridge/os_call/readonly_fs_provider.dart';
export 'src/bridge/os_call/sandboxed_fs_provider_stub.dart'
    if (dart.library.io) 'src/bridge/os_call/sandboxed_fs_provider.dart';
export 'src/bridge/os_call/time_os_provider.dart';
export 'src/bridge/plugins/event_loop_plugin.dart';
export 'src/bridge/plugins/message_bus_plugin.dart';
export 'src/bridge/plugins/sandbox_plugin.dart';
export 'src/bridge/plugins/template_plugin.dart';
