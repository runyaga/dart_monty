import 'dart:collection';

import 'package:dart_monty_bridge/src/bridge/host_function_schema.dart';
import 'package:dart_monty_bridge/src/bridge/introspection_functions.dart';
import 'package:dart_monty_bridge/src/bridge/monty_bridge.dart';
import 'package:dart_monty_bridge/src/bridge/monty_plugin.dart';
import 'package:dart_monty_bridge/src/bridge/plugin_ref.dart';
import 'package:struct_log/struct_log.dart';

/// Collects [MontyPlugin]s with namespace validation and function name
/// collision detection.
///
/// All function names must be prefixed with the plugin's namespace followed
/// by an underscore (e.g., namespace `sqlite` requires functions named
/// `sqlite_query`, `sqlite_execute`, etc.).
class PluginRegistry {
  final List<MontyPlugin> _plugins = [];
  List<MontyPlugin>? _attachOrder;
  final Set<String> _namespaces = {};
  final Set<String> _functionNames = {};
  final Logger _log = LogManager.instance.getLogger('PluginRegistry');

  static final RegExp _validNamespace = RegExp(r'^[a-z][a-z0-9_]*$');
  static const int _maxNamespaceLength = 32;
  static const Set<String> _reservedNamespaces = {'introspection'};

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

  /// Wires all plugins to [bridge], calls [MontyPlugin.onRegister] for each,
  /// and registers introspection builtins.
  ///
  /// All plugins are wired even if some [MontyPlugin.onRegister] calls throw —
  /// errors are collected and thrown as a single [StateError] after all plugins
  /// have been attached.
  Future<void> attachTo(MontyBridge bridge) async {
    final schemasByCategory = <String, List<HostFunctionSchema>>{};
    final errors = <(String, Object)>[];

    for (final plugin in _plugins) {
      final schemas = <HostFunctionSchema>[];
      for (final fn in plugin.functions) {
        bridge.register(fn);
        schemas.add(fn.schema);
      }
      schemasByCategory[plugin.namespace] = schemas;
    }

    // Resolve dependencies and get topologically sorted order
    // (dependencies before dependents). Stored for reverse disposal.
    final sorted = _resolveDependencies();
    _attachOrder = sorted;

    for (final plugin in sorted) {
      try {
        await plugin.onRegister(bridge);
      } on Object catch (e) {
        _log.warning(
          'Plugin onRegister failed',
          attributes: {'namespace': plugin.namespace, 'error': '$e'},
        );
        errors.add((plugin.namespace, e));
      }
    }

    // Register introspection builtins.
    buildIntrospectionFunctions(schemasByCategory).forEach(bridge.register);
    _log.info(
      'Attached plugins to bridge',
      attributes: {'pluginCount': _plugins.length},
    );

    if (errors.isNotEmpty) {
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError(
        '${errors.length} plugin(s) failed to attach: $summary',
      );
    }
  }

  /// Disposes all plugins in reverse registration order.
  ///
  /// All plugins are disposed even if some throw — errors are collected and
  /// thrown as a single [StateError] after all plugins have been disposed.
  /// Safe to call multiple times — each plugin's [MontyPlugin.onDispose]
  /// must be idempotent.
  Future<void> disposeAll() async {
    final errors = <(String, Object)>[];
    // Use reverse topological order (dependents before dependencies).
    // Falls back to reverse insertion order if attachTo was never called.
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

  /// Resolves [PluginRef]s, detects cycles, and returns a topologically
  /// sorted plugin list (dependencies before dependents).
  List<MontyPlugin> _resolveDependencies() {
    // Resolve each ref using polymorphic `is T` matching.
    for (final plugin in _plugins) {
      if (plugin is! CompositePlugin) continue;
      for (final ref in plugin.dependencies) {
        MontyPlugin? target;
        for (final candidate in _plugins) {
          if (ref.accepts(candidate)) {
            target = candidate;
            break;
          }
        }
        if (target == null) {
          if (ref.required) {
            throw StateError(
              'Plugin "${plugin.namespace}" has an unresolvable '
              'required dependency. No registered plugin matches.',
            );
          }
          continue;
        }
        ref.bind(target);
      }
    }

    // Topological sort via DFS — also detects cycles.
    return _topologicalSort();
  }

  /// Returns plugins in topological order (dependencies first).
  ///
  /// Throws [StateError] if a cycle is detected.
  List<MontyPlugin> _topologicalSort() {
    final visiting = <String>{};
    final visited = <String>{};
    final sorted = <MontyPlugin>[];

    void dfs(MontyPlugin plugin) {
      final ns = plugin.namespace;
      if (visited.contains(ns)) return;
      if (visiting.contains(ns)) {
        throw StateError(
          'Circular dependency detected involving "$ns".',
        );
      }
      visiting.add(ns);
      if (plugin case final CompositePlugin composite) {
        for (final ref in composite.dependencies) {
          if (ref.isResolved) dfs(ref.plugin);
        }
      }
      visiting.remove(ns);
      visited.add(ns);
      sorted.add(plugin);
    }

    _plugins.forEach(dfs);
    return sorted;
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
