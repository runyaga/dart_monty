/// High-level bridge layer for dart_monty.
///
/// Provides host function infrastructure, the default bridge implementation,
/// event loop support, and a plugin system for modular host function bundles.
library;

export 'src/bridge/bridge_event.dart';
export 'src/bridge/default_monty_bridge.dart';
export 'src/bridge/event_loop_bridge.dart';
export 'src/bridge/host_function.dart';
export 'src/bridge/host_function_registry.dart';
export 'src/bridge/host_function_schema.dart';
export 'src/bridge/host_param.dart';
export 'src/bridge/host_param_type.dart';
export 'src/bridge/introspection_functions.dart';
export 'src/bridge/monty_bridge.dart';
export 'src/bridge/monty_plugin.dart';
export 'src/bridge/plugin_registry.dart';
export 'src/plugins/isolate_plugin.dart';
