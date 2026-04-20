import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/plugins/event_loop_plugin.dart';
import 'package:dart_monty/src/plugins/message_bus_plugin.dart';
import 'package:dart_monty/src/plugins/sandbox_plugin.dart';
import 'package:dart_monty/src/plugins/template_plugin.dart';

/// Returns a fresh list of the extensions most scripts expect to have available.
///
/// Includes the extensions that have no required configuration and are
/// useful in the majority of embedding contexts:
///
/// - [JinjaTemplatePlugin] — `tmpl_render`
/// - [MessageBusPlugin] — `msg_send`, `msg_recv`, `msg_peek`, `msg_close`,
///   `msg_stats`
/// - [EventLoopPlugin] — `el_recv`, `el_emit`
///
/// Not included: [SandboxPlugin] (requires a `platformFactory`), and extensions
/// that depend on external services (HTTP, storage, logging — those live in
/// `dart_monty_plugins`).
///
/// ```dart
/// final session = MontyRuntime(
///   extensions: [...defaultExtensions(), MyCustomExtension()],
///   osHandlers: {'Path.': memoryFsHandler()},
/// );
/// ```
List<MontyExtension> defaultExtensions() => [
  JinjaTemplatePlugin(),
  MessageBusPlugin(),
  EventLoopPlugin(),
];
