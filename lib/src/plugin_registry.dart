import 'dart:collection';

import 'package:dart_monty/src/bridge_logger.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/introspection_functions.dart';
import 'package:dart_monty/src/monty_backend_kind.dart';
import 'package:dart_monty/src/monty_bridge.dart';
import 'package:dart_monty/src/monty_plugin.dart';
import 'package:dart_monty/src/plugin_host.dart';
import 'package:dart_monty/src/os_call/decorator_handlers.dart';
import 'package:dart_monty/src/os_call/fs_handlers.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/stateful_plugin.dart';
import 'package:signals_core/signals_core.dart';

/// How a child sandbox's `Path.` handler is derived from the parent's.
///
/// Passed to [PluginRegistry.spawnChild] to control filesystem visibility
/// between parent and child. All strategies forward non-`Path.` prefixes
/// (`os.`, `date.`, `datetime.`, etc.) to the parent unchanged.
enum ChildVfsStrategy {
  /// Fresh in-memory filesystem. Parent's `Path.` is invisible to the child.
  ///
  /// This is the safe default and matches the pre-M1 `SandboxPlugin`
  /// behavior.
  isolated,

  /// Child shares the parent's `Path.` handler directly.
  ///
  /// Reads and writes are immediately visible to the parent. Use when the
  /// child intentionally extends the parent's workspace (e.g., a coordinated
  /// build step).
  shared,

  /// Child reads from the parent's `Path.` but writes go to a fresh
  /// in-memory scratch layer. Copy-on-write.
  ///
  /// Parent is never modified. Use for transient sub-scripts that should see
  /// the parent's files but whose changes should not escape.
  overlay,
}

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

/// Validates every plugin's [MontyPlugin.supportedBackends] against
/// [currentBackendKind]. Logs and throws [UnsupportedBackendError] on the
/// first mismatch so the failure is a clean configuration error before any
/// lifecycle hook fires.
void _checkSupportedBackends(List<MontyPlugin> plugins, BridgeLogger log) {
  final here = currentBackendKind;
  for (final plugin in plugins) {
    final supported = plugin.supportedBackends;
    if (supported.contains(here)) continue;
    final error = UnsupportedBackendError(
      pluginNamespace: plugin.namespace,
      current: here,
      supported: supported,
    );
    log.error(
      'plugin does not support current backend',
      attributes: {
        'namespace': plugin.namespace,
        'current': here.name,
        'supported': supported.map((b) => b.name).toList(),
      },
    );
    throw error;
  }
}

/// Emits a `plugin registered` info log per plugin with namespace,
/// function count, and declared supported backends.
void _logPluginsRegistered(
  List<MontyPlugin> attachOrder,
  BridgeLogger log,
) {
  for (final plugin in attachOrder) {
    log.info(
      'plugin registered',
      attributes: {
        'namespace': plugin.namespace,
        'functionCount': plugin.functions.length,
        'supportedBackends': plugin.supportedBackends
            .map((b) => b.name)
            .toList(),
      },
    );
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
  PluginHost host,
  BridgeLogger log,
) async {
  final errors = <(String, Object)>[];
  for (final plugin in attachOrder) {
    try {
      await plugin.onRegister(host);
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

/// Injects [registry] into each plugin's [MontyPlugin.registry] field.
///
/// Called before [_runPluginOnRegisters] so that [MontyPlugin.sibling] is
/// available inside [MontyPlugin.onRegister].
void _injectRegistries(
  List<MontyPlugin> attachOrder,
  PluginRegistry registry,
) {
  for (final plugin in attachOrder) {
    plugin.registry = registry;
  }
}

/// Collects OS call prefix contributions from all plugins in [attachOrder]
/// and validates that no two plugins claim the same prefix.
///
/// Throws [StateError] if two plugins return the same prefix key from
/// [MontyPlugin.osContribution].
Map<String, OsCallHandler> _collectOsContributions(
  List<MontyPlugin> attachOrder,
) {
  // prefix → (owning namespace, handler)
  final merged = <String, (String, OsCallHandler)>{};

  for (final plugin in attachOrder) {
    final contrib = plugin.osContribution;
    if (contrib == null) continue;
    for (final entry in contrib.entries) {
      final prefix = entry.key;
      if (merged.containsKey(prefix)) {
        final owner = merged[prefix]!.$1;
        throw StateError(
          'OS prefix "$prefix" is claimed by both "${plugin.namespace}" and '
          '"$owner". Each prefix may be claimed by at most one plugin.',
        );
      }
      merged[prefix] = (plugin.namespace, entry.value);
    }
  }

  return {
    for (final e in merged.entries) e.key: e.value.$2,
  };
}

/// Composes [contributions] with [baseOs] as fallback and registers the result
/// on [bridge]. No-op when there are no contributions and [baseOs] is `null`.
void _applyOsContributions(
  MontyBridge bridge,
  Map<String, OsCallHandler> contributions,
  OsCallHandler? baseOs,
) {
  if (contributions.isEmpty && baseOs == null) return;

  final composed = contributions.isNotEmpty
      ? composeOsHandlers(contributions, fallback: baseOs)
      : baseOs!;
  bridge.registerOs(composed);
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

  /// The plugin OS contributions resolved during [attachTo], keyed by prefix.
  ///
  /// Captured so that [spawnChild] can re-compose a child handler per
  /// [ChildVfsStrategy] (swapping only the `Path.` entry) instead of
  /// opaquely delegating to the already-composed parent handler.
  Map<String, OsCallHandler>? _osContributions;

  /// The `baseOs` passed to [attachTo], if any. Used as the fallback for any
  /// prefix that no plugin claims when [spawnChild] composes a child handler.
  OsCallHandler? _baseOs;

  static final RegExp _validNamespace = RegExp(r'^[a-z][a-z0-9_]*$');
  static const int _maxNamespaceLength = 32;
  static const Set<String> _reservedNamespaces = {'introspection', 'extra'};

  /// Registered plugins in insertion order (unmodifiable).
  List<MontyPlugin> get plugins => UnmodifiableListView(_plugins);

  /// Validates [plugin] namespace and function names, then registers it.
  ///
  /// Throws [ArgumentError] if the namespace is empty, malformed, or exceeds
  /// 32 characters.
  /// Throws [StateError] if the namespace is reserved, already registered,
  /// any function name collides with a previously registered function, or
  /// [attachTo] has already been called.
  void register(MontyPlugin plugin) {
    if (_attached) {
      throw StateError(
        'Cannot register plugin "${plugin.namespace}" after attachTo() '
        'has been called. Create a new PluginRegistry.',
      );
    }
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
  ///
  /// ## OS registration
  ///
  /// If any plugins return a non-null [MontyPlugin.osContribution], their
  /// prefix maps are merged (overlapping prefixes throw [StateError]) and
  /// composed with [baseOs] as the fallback. The composed handler is then
  /// registered on [bridge] via `registerOs`. If there are no contributions
  /// and [baseOs] is non-null, [baseOs] is registered directly.
  ///
  /// ## Registry injection
  ///
  /// [MontyPlugin.registry] is set to this registry before
  /// [MontyPlugin.onRegister] is called, so [MontyPlugin.sibling] is
  /// available inside [MontyPlugin.onRegister].
  Future<void> attachTo(
    MontyBridge bridge, {
    List<HostFunction>? extraFunctions,
    bool enableIntrospection = true,
    OsCallHandler? baseOs,
  }) async {
    if (_attached) {
      throw StateError(
        'PluginRegistry.attachTo() has already been called. '
        'Create a new PluginRegistry for a different bridge.',
      );
    }

    _log = bridge.logger.child('registry');

    _checkSupportedBackends(_plugins, _log);

    // Sort by descending priority; stable sort preserves insertion order for
    // equal priorities. High-priority plugins attach first, dispose last.
    final attachOrder = [..._plugins]
      ..sort((a, b) => b.priority.compareTo(a.priority));
    _attachOrder = attachOrder;

    // Inject registry before onRegister so sibling() works during lifecycle.
    _injectRegistries(attachOrder, this);

    _attachPluginFunctions(attachOrder, bridge);
    _logPluginsRegistered(attachOrder, _log);
    final contributions = _collectOsContributions(attachOrder);
    _osContributions = contributions;
    _baseOs = baseOs;
    _applyOsContributions(bridge, contributions, baseOs);
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

  /// Builds a child [PluginRegistry] seeded from this (parent) registry and
  /// attaches it to [bridge].
  ///
  /// Every parent plugin gets the chance to contribute a child instance via
  /// [MontyPlugin.createChildInstance]; plugins that return `null` are
  /// skipped. The resulting registry is attached to [bridge] with an OS
  /// handler composed per [vfsStrategy] (see [ChildVfsStrategy]).
  ///
  /// Non-`Path.` OS prefixes (e.g., `os.`, `date.`, `datetime.`) are
  /// forwarded to the parent unchanged, and the parent's [attachTo] `baseOs`
  /// is used as the child's fallback for any unclaimed prefix.
  ///
  /// Throws [StateError] if [attachTo] has not yet been called on this
  /// registry — there is no parent OS state to inherit from.
  Future<PluginRegistry> spawnChild({
    required ChildSpawnContext context,
    required MontyBridge bridge,
    ChildVfsStrategy vfsStrategy = ChildVfsStrategy.isolated,
    String? childSystemPromptPrefix,
  }) async {
    if (!_attached) {
      throw StateError(
        'PluginRegistry.spawnChild() called before attachTo(). '
        'A parent registry must be attached before spawning children.',
      );
    }

    final child = PluginRegistry();
    for (final plugin in _plugins) {
      final instance = plugin.createChildInstance(context: context);
      if (instance == null) continue;
      assert(
        !identical(instance, plugin),
        'createChildInstance() must return a new instance, not `this`.',
      );
      child.register(instance);
    }

    child.systemPromptPrefix = childSystemPromptPrefix;
    final childBaseOs = _composeChildBaseOs(vfsStrategy);
    await child.attachTo(bridge, baseOs: childBaseOs);

    return child;
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

  /// Returns one `(namespace, signal)` pair per plugin that mixes in
  /// [StatefulPlugin].
  ///
  /// Consumers (e.g., an ag-ui session adapter) use these pairs to subscribe
  /// to plugin state and emit `STATE_SNAPSHOT` + `STATE_DELTA` frames keyed
  /// as `plugin.<namespace>`.
  Iterable<(String, ReadonlySignal<Object?>)> statefulObservations() sync* {
    for (final plugin in _plugins) {
      if (plugin is HasStateSignal) {
        yield (plugin.namespace, plugin.stateSignalAsObject);
      }
    }
  }

  /// Builds a composed child [OsCallHandler] from the parent's captured
  /// contributions and [strategy]. Returns `null` when the parent has no OS
  /// state at all (nothing to inherit).
  OsCallHandler? _composeChildBaseOs(ChildVfsStrategy strategy) {
    final parentOs = _osContributions;
    final parentBase = _baseOs;
    if ((parentOs == null || parentOs.isEmpty) && parentBase == null) {
      return null;
    }

    final parentPath = parentOs?['Path.'];
    final childPath = switch (strategy) {
      ChildVfsStrategy.isolated => memoryFsHandler(),
      ChildVfsStrategy.shared => parentPath ?? memoryFsHandler(),
      ChildVfsStrategy.overlay =>
        parentPath == null
            ? memoryFsHandler()
            : overlayFsHandler(base: parentPath, scratch: memoryFsHandler()),
    };

    final childHandlers = {
      if (parentOs != null)
        for (final entry in parentOs.entries)
          if (entry.key != 'Path.') entry.key: entry.value,
      'Path.': childPath,
    };

    return composeOsHandlers(childHandlers, fallback: parentBase);
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
