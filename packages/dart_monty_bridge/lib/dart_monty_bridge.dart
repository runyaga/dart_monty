/// High-level bridge layer for dart_monty.
///
/// Wraps the low-level `start()`/`resume()` loop from `dart_monty` into
/// a stream-based API with host function dispatch, argument validation,
/// and a plugin system.
///
/// ## Installation
///
/// This is a **separate package** from `dart_monty`:
///
/// ```bash
/// dart pub add dart_monty_bridge
/// ```
///
/// ## Quick Start
///
/// ```dart
/// import 'package:dart_monty/dart_monty.dart';
/// import 'package:dart_monty_bridge/dart_monty_bridge.dart';
///
/// final bridge = DefaultMontyBridge(platform: Monty());
/// bridge.register(HostFunction(
///   schema: const HostFunctionSchema(
///     name: 'greet',
///     description: 'Returns a greeting.',
///     params: [HostParam(name: 'name', type: HostParamType.string)],
///   ),
///   handler: (args) async => 'Hello, ${args["name"]}!',
/// ));
/// ```
///
/// ## Key Types
///
/// | Category | Types |
/// |----------|-------|
/// | **Bridge** | `DefaultMontyBridge`, `MontyBridge`, `EventLoopBridge` |
/// | **Host Functions** | `HostFunction`, `HostFunctionSchema`, `HostParam` |
/// | **Plugins** | `MontyPlugin`, `PluginRegistry` |
/// | **Events** | `BridgeEvent`, `BridgeRunFinished`, `BridgeToolCallResult` |
library;

export 'src/bridge/bridge_event.dart';
export 'src/bridge/bridge_middleware.dart';
export 'src/bridge/default_monty_bridge.dart';
export 'src/bridge/event_loop_bridge.dart';
export 'src/bridge/host_function.dart';
export 'src/bridge/host_function_schema.dart';
export 'src/bridge/host_param.dart';
export 'src/bridge/host_param_type.dart';
export 'src/bridge/monty_bridge.dart';
export 'src/bridge/monty_plugin.dart';
export 'src/bridge/plugin_registry.dart';
export 'src/bridge/struct_log_bridge_logger.dart';
export 'src/plugins/message_bus_plugin.dart';
export 'src/plugins/sandbox_plugin.dart';
export 'src/plugins/template_plugin.dart';
