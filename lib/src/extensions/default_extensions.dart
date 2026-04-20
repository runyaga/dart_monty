import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/extensions/event_loop_extension.dart';
import 'package:dart_monty/src/extensions/message_bus_extension.dart';
import 'package:dart_monty/src/extensions/sandbox_extension.dart';
import 'package:dart_monty/src/extensions/template_extension.dart';

/// Returns a fresh list of the extensions most scripts expect to have available.
///
/// Includes the extensions that have no required configuration and are
/// useful in the majority of embedding contexts:
///
/// - [JinjaTemplateExtension] — `tmpl_render`
/// - [MessageBusExtension] — `msg_send`, `msg_recv`, `msg_peek`, `msg_close`,
///   `msg_stats`
/// - [EventLoopExtension] — `el_recv`, `el_emit`
///
/// Not included: [SandboxExtension] (requires a `platformFactory`), and extensions
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
  JinjaTemplateExtension(),
  MessageBusExtension(),
  EventLoopExtension(),
];
