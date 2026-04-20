import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/extensions/event_loop.dart';
import 'package:dart_monty/src/extensions/jinja_template.dart';
import 'package:dart_monty/src/extensions/message_bus.dart';
import 'package:dart_monty/src/extensions/sandbox.dart';

/// Returns a fresh list of the extensions most scripts expect to have
/// available.
///
/// Includes the extensions that have no required configuration and are
/// useful in the majority of embedding contexts:
///
/// - [JinjaTemplateExtension] — `tmpl_render`
/// - [MessageBusExtension] — `msg_send`, `msg_recv`, `msg_peek`, `msg_close`,
///   `msg_stats`
/// - [EventLoopExtension] — `el_recv`, `el_emit`
///
/// Not included: [SandboxExtension] (requires a `platformFactory`), and
/// extensions that depend on external services (HTTP, storage, logging —
/// those live in
/// `dart_monty_extensions`).
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
