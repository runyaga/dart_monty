import 'dart:collection';

import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/introspection_functions.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:dart_monty/src/platform/bridge_logger.dart';

// ---------------------------------------------------------------------------
// Top-level helpers used by PluginRegistry.attachTo.
// ---------------------------------------------------------------------------

/// Injects scoped loggers and registers all plugin functions with [bridge].
void _attachPluginFunctions(
  List<MontyPlugin> attachOrder,
  MontyBridge bridge,
) {
  for (final plugin in attachOrder) {
    plugin.logger = bridge.logger.child(plugin.namespace);
    for (final fn in plugin.functions) {
      bridge.register(fn, category: plugin.namespace);
    }
  }
}

/// Registers [extraFunctions] under the `'extra'` category and logs the count.
void _attachExtraFunctions(
  List<HostFunction> extraFunctions,
  MontyBridge bridge,
  BridgeLogger log,
) {
  for (final fn in extraFunctions) {
    bridge.register(fn, category: 'extra');
  }
  log.debug(
    'Registered extra functions',
    attributes: {'count': extraFunctions.length},
  );
}

/// Calls [MontyPlugin.onRegister] for each plugin in [attachOrder], collecting
/// failures. Returns `(namespace, error)` pairs for every plugin that threw.
Future<List<(String, Object)>> _runPluginOnRegisters(
  List<MontyPlugin> attachOrder,
  MontyBridge bridge,
  BridgeLogger log,
) async {
  final errors = <(String, Object)>[];
  for (final plugin in attachOrder) {
    try {
      await plugin.onRegister(bridge);
    } on Object catch (e) {
      log.warning(
        'Plugin onRegister failed',
        attributes: {'namespace': plugin.namespace, 'error': '$e'},
      );
      errors.add((plugin.namespace, e));
    }
  }

  return errors;
}

/// Collects [MontyPlugin]s with namespace validation and function name
/// collision detection.
///
/// All function names must be prefixed with the plugin's namespace followed
/// by an underscore (e.g., namespace `sqlite` requires functions named
/// `sqlite_query`, `sqlite_execute`, etc.).
class PluginRegistry {
  /// Optional text prepended before plugin sections in the system prompt.
  ///
  /// Set by `SandboxPlugin._handleSpawn` after registry construction to
  /// inject per-child system prompt content. Using a public field (rather
  /// than a constructor param) guarantees injection regardless of whether
  /// the registry was built by inheritance or a custom factory.
  String? systemPromptPrefix;

  final List<MontyPlugin> _plugins = [];
  List<MontyPlugin>? _attachOrder;
  final Set<String> _namespaces = {};
  final Set<String> _functionNames = {};
  BridgeLogger _log = const NullBridgeLogger();
  bool _attached = false;

  static final RegExp _validNamespace = RegExp(r'^[a-z][a-z0-9_]*$');
  static const int _maxNamespaceLength = 32;
  static const Set<String> _reservedNamespaces = {'introspection', 'extra'};

  /// Registered plugins in insertion order (unmodifiable).
  List<MontyPlugin> get plugins => UnmodifiableListView(_plugins);

  /// Validates [plugin] namespace and function names, then registers it.
  ///
  /// Throws [ArgumentError] if the namespace is empty, malformed, or exceeds
  /// 32 characters.
  /// Throws [StateError] if the namespace is reserved, already registered, or
  /// any function name collides with a previously registered function.
  void register(MontyPlugin plugin) {
    _validateNamespace(plugin.namespace);
    _checkFunctionCollisions(plugin);

    _namespaces.add(plugin.namespace);
    for (final fn in plugin.functions) {
      _functionNames.add(fn.schema.name);
    }
    _plugins.add(plugin);
    _log.debug(
      'Registered plugin',
      attributes: {
        'namespace': plugin.namespace,
        'functions': plugin.functions.length,
      },
    );
  }

  /// Wires all plugins to [bridge], calls [MontyPlugin.onRegister] for each,
  /// registers introspection builtins, and registers [extraFunctions] under the
  /// `'extra'` category. [MontyPlugin.onRegister] errors are collected and
  /// thrown together as a single [StateError] after all plugins are processed.
  Future<void> attachTo(
    MontyBridge bridge, {
    List<HostFunction>? extraFunctions,
    bool enableIntrospection = true,
  }) async {
    if (_attached) {
      throw StateError(
        'PluginRegistry.attachTo() has already been called. '
        'Create a new PluginRegistry for a different bridge.',
      );
    }

    _log = bridge.logger.child('registry');

    // Sort by descending priority; stable sort preserves insertion order for
    // equal priorities. High-priority plugins attach first, dispose last.
    final attachOrder = [..._plugins]
      ..sort((a, b) => b.priority.compareTo(a.priority));
    _attachOrder = attachOrder;

    _attachPluginFunctions(attachOrder, bridge);
    if (extraFunctions != null && extraFunctions.isNotEmpty) {
      _attachExtraFunctions(extraFunctions, bridge, _log);
    }

    final errors = await _runPluginOnRegisters(attachOrder, bridge, _log);

    if (enableIntrospection) {
      for (final fn in buildIntrospectionFunctions(bridge)) {
        bridge.register(fn, category: introspectionCategory);
      }
    }

    if (errors.isNotEmpty) {
      // Clean up partially-attached plugins before throwing.
      await disposeAll();
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError('${errors.length} plugin(s) failed to attach: $summary');
    }

    _attached = true;
    _log.info(
      'Attached plugins to bridge',
      attributes: {'pluginCount': _plugins.length},
    );
  }

  /// Disposes all plugins in reverse registration order.
  ///
  /// All plugins are disposed even if some throw — errors are collected and
  /// thrown as a single [StateError] after all plugins have been disposed.
  /// Safe to call multiple times — each plugin's [MontyPlugin.onDispose]
  /// must be idempotent.
  Future<void> disposeAll() async {
    final errors = <(String, Object)>[];
    // Reverse registration order so later-registered plugins dispose first.
    final disposeOrder = (_attachOrder ?? _plugins).reversed;
    for (final plugin in disposeOrder) {
      try {
        await plugin.onDispose();
      } on Object catch (e) {
        _log.warning(
          'Plugin dispose failed',
          attributes: {'namespace': plugin.namespace, 'error': '$e'},
        );
        errors.add((plugin.namespace, e));
      }
    }
    if (errors.isNotEmpty) {
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError(
        '${errors.length} plugin(s) failed to dispose: $summary',
      );
    }
  }

  /// Auto-generates an LLM system prompt from plugin schemas.
  ///
  /// Each plugin produces a markdown section with its namespace as heading,
  /// optional [MontyPlugin.systemPromptContext], and a list of functions.
  String generateSystemPrompt() {
    final buffer = StringBuffer();

    if (systemPromptPrefix != null && systemPromptPrefix!.isNotEmpty) {
      buffer
        ..writeln(systemPromptPrefix)
        ..writeln();
    }

    for (final plugin in _plugins) {
      buffer.writeln('### ${plugin.namespace}');
      final context = plugin.systemPromptContext;
      if (context != null && context.isNotEmpty) {
        buffer.writeln(context);
      }
      for (final fn in plugin.functions) {
        final params = fn.schema.params
            .map(
              (p) =>
                  '${p.name}'
                  '${p.isRequired ? '' : '?'}'
                  ': ${p.type.jsonSchemaType}',
            )
            .join(', ');
        buffer.writeln(
          '- `${fn.schema.name}($params)`:'
          ' ${fn.schema.description}',
        );
      }
      buffer.writeln();
    }

    return buffer.toString().trimRight();
  }

  void _validateNamespace(String namespace) {
    if (namespace.isEmpty) {
      throw ArgumentError('Namespace must not be empty.');
    }
    if (namespace.length > _maxNamespaceLength) {
      throw ArgumentError(
        'Namespace "$namespace" exceeds maximum length of '
        '$_maxNamespaceLength characters.',
      );
    }
    if (!_validNamespace.hasMatch(namespace)) {
      throw ArgumentError(
        'Namespace "$namespace" contains invalid characters. '
        'Must match [a-z][a-z0-9_]*.',
      );
    }
    if (_reservedNamespaces.contains(namespace)) {
      throw StateError('Namespace "$namespace" is reserved.');
    }
    if (_namespaces.contains(namespace)) {
      throw StateError('Namespace "$namespace" already registered.');
    }
  }

  void _checkFunctionCollisions(MontyPlugin plugin) {
    final prefix = '${plugin.namespace}_';
    final seen = <String>{};
    for (final fn in plugin.functions) {
      final name = fn.schema.name;
      if (!name.startsWith(prefix)) {
        throw ArgumentError(
          'Function "$name" in plugin "${plugin.namespace}" must be '
          'prefixed with "$prefix".',
        );
      }
      if (!seen.add(name)) {
        throw ArgumentError(
          'Plugin "${plugin.namespace}" declares duplicate '
          'function "$name".',
        );
      }
      if (_functionNames.contains(name)) {
        throw StateError(
          'Function "$name" from plugin "${plugin.namespace}" conflicts '
          'with an already registered function.',
        );
      }
    }
  }
}
