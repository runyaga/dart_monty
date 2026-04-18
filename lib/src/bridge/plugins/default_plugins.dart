import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/event_loop_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/message_bus_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/sandbox_plugin.dart';
import 'package:dart_monty/src/bridge/plugins/template_plugin.dart';

/// Returns a fresh list of the plugins most scripts expect to have available.
///
/// Includes the plugins that have no required configuration and are
/// useful in the majority of embedding contexts:
///
/// - [JinjaTemplatePlugin] — `tmpl_render`
/// - [MessageBusPlugin] — `mb_publish`, `mb_subscribe`
/// - [EventLoopPlugin] — `el_recv`, `el_emit`
///
/// Not included: [SandboxPlugin] (requires a `platformFactory`), and plugins
/// that depend on external services (HTTP, storage, logging — those live in
/// `dart_monty_plugins`).
///
/// ```dart
/// final session = AgentSession(
///   plugins: [...defaultPlugins(), MyCustomPlugin()],
///   osHandlers: {'Path.': memoryFsHandler()},
/// );
/// ```
List<MontyPlugin> defaultPlugins() => [
  JinjaTemplatePlugin(),
  MessageBusPlugin(),
  EventLoopPlugin(),
];
