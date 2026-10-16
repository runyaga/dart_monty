import 'dart:collection';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/introspection_functions.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
import 'package:dart_monty/src/workspace/workspace.dart';

// ---------------------------------------------------------------------------
// Top-level helpers used by ExtensionCoordinator.attachTo.
// ---------------------------------------------------------------------------

/// Injects scoped loggers and registers all extension functions with [bridge].
void _attachExtensionFunctions(
  List<MontyExtension> attachOrder,
  MontyBridge bridge,
) {
  for (final ext in attachOrder) {
    ext.logger = bridge.logger.child(ext.namespace);
    for (final fn in ext.functions) {
      bridge.register(fn, category: ext.namespace);
    }
  }
}

/// Validates every extension's [MontyExtension.supportedBackends] against
/// [currentBackendKind]. Logs and throws [UnsupportedBackendError] on the
/// first mismatch so the failure is a clean configuration error before any
/// lifecycle hook fires.
void _checkSupportedBackends(
  List<MontyExtension> extensions,
  BridgeLogger log,
) {
  final here = currentBackendKind;
  for (final ext in extensions) {
    final supported = ext.supportedBackends;
    if (supported.contains(here)) continue;
    final error = UnsupportedBackendError(
      extensionNamespace: ext.namespace,
      current: here,
      supported: supported,
    );
    log.error(
      'extension does not support current backend',
      attributes: {
        'namespace': ext.namespace,
        'current': here.name,
        'supported': supported.map((b) => b.name).toList(),
      },
    );
    throw error;
  }
}

/// Emits an `extension registered` info log per extension with namespace,
/// function count, and declared supported backends.
void _logExtensionsRegistered(
  List<MontyExtension> attachOrder,
  BridgeLogger log,
) {
  for (final ext in attachOrder) {
    log.info(
      'extension registered',
      attributes: {
        'namespace': ext.namespace,
        'functionCount': ext.functions.length,
        'supportedBackends': ext.supportedBackends.map((b) => b.name).toList(),
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

/// Calls [MontyExtension.onAttach] for each extension in [attachOrder],
/// collecting failures. Returns `(namespace, error)` pairs for every
/// extension that threw.
Future<List<(String, Object)>> _runExtensionOnAttaches(
  List<MontyExtension> attachOrder,
  AttachContext ctx,
  BridgeLogger log,
) async {
  final errors = <(String, Object)>[];
  for (final ext in attachOrder) {
    try {
      await ext.onAttach(ctx);
    } on Object catch (e) {
      log.warning(
        'Extension onAttach failed',
        attributes: {'namespace': ext.namespace, 'error': '$e'},
      );
      errors.add((ext.namespace, e));
    }
  }

  return errors;
}

/// The coordinator each extension was last attached through.
final Expando<ExtensionCoordinator> _owners = Expando('coordinator');

/// The coordinator [extension] was last attached through, for extensions
/// that spawn children (`SandboxExtension`). Internal to dm.
///
/// Throws [StateError] when [extension] was never attached.
ExtensionCoordinator coordinatorOf(MontyExtension extension) =>
    _owners[extension] ??
    (throw StateError(
      'Extension "${extension.namespace}" is not attached to a runtime.',
    ));

/// Records [coordinator] as the owner of each extension in [attachOrder],
/// before [_runExtensionOnAttaches], so [coordinatorOf] works inside
/// [MontyExtension.onAttach].
void _injectCoordinators(
  List<MontyExtension> attachOrder,
  ExtensionCoordinator coordinator,
) {
  for (final ext in attachOrder) {
    _owners[ext] = coordinator;
  }
}

/// Collects OS call prefix contributions from all extensions in [attachOrder]
/// and validates that no two extensions claim the same prefix.
///
/// Throws [StateError] if two extensions return the same prefix key from
/// [MontyExtension.osContribution].
Map<String, OsHandler> _collectOsContributions(
  List<MontyExtension> attachOrder,
) {
  // prefix → (owning namespace, handler)
  final merged = <String, (String, OsHandler)>{};

  for (final ext in attachOrder) {
    final contrib = ext.osContribution;
    if (contrib == null) continue;
    for (final entry in contrib.entries) {
      final prefix = entry.key;
      if (merged.containsKey(prefix)) {
        final owner = merged[prefix]!.$1;
        throw StateError(
          'OS prefix "$prefix" is claimed by both "${ext.namespace}" and '
          '"$owner". Each prefix may be claimed by at most one extension.',
        );
      }
      merged[prefix] = (ext.namespace, entry.value);
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
  Map<String, OsHandler> contributions,
  OsHandler? baseOs,
) {
  if (contributions.isEmpty && baseOs == null) return;

  final composed = contributions.isNotEmpty
      ? composeOsHandlers(contributions, fallback: baseOs)
      : baseOs!;
  bridge.registerOs(composed);
}

/// Collects [MontyExtension]s with namespace validation and function name
/// collision detection.
///
/// All function names must be prefixed with the extension's namespace followed
/// by an underscore (e.g., namespace `sqlite` requires functions named
/// `sqlite_query`, `sqlite_execute`, etc.).
class ExtensionCoordinator {
  final List<MontyExtension> _extensions = [];
  List<MontyExtension>? _attachOrder;
  final Set<String> _namespaces = {};
  final Set<String> _functionNames = {};
  BridgeLogger _log = BridgeLogger.silent;
  bool _attached = false;

  /// The extension OS contributions resolved during [attachTo], keyed by
  /// prefix.
  ///
  /// Captured so that [spawnChild] can re-compose a child handler per
  /// its private workspace (including bare `open`) instead of
  /// opaquely delegating to the already-composed parent handler.
  Map<String, OsHandler>? _osContributions;

  /// The `baseOs` passed to [attachTo], if any. Used as the fallback for any
  /// prefix that no extension claims when [spawnChild] composes a child
  /// handler.
  OsHandler? _baseOs;

  static final RegExp _validNamespace = RegExp(r'^[a-z][a-z0-9_]*$');
  static const int _maxNamespaceLength = 32;
  static const Set<String> _reservedNamespaces = {'introspection', 'extra'};

  /// Registered extensions in insertion order (unmodifiable).
  List<MontyExtension> get extensions => UnmodifiableListView(_extensions);

  /// Validates [extension] namespace and function names, then registers it.
  ///
  /// Throws [ArgumentError] if the namespace is empty, malformed, or exceeds
  /// 32 characters.
  /// Throws [StateError] if the namespace is reserved, already registered,
  /// any function name collides with a previously registered function, or
  /// [attachTo] has already been called.
  void register(MontyExtension extension) {
    if (_attached) {
      throw StateError(
        'Cannot register extension "${extension.namespace}" after attachTo() '
        'has been called. Create a new ExtensionCoordinator.',
      );
    }
    _validateNamespace(extension.namespace);
    _checkFunctionCollisions(extension);

    _namespaces.add(extension.namespace);
    for (final fn in extension.functions) {
      _functionNames.add(fn.schema.name);
    }
    _extensions.add(extension);
    _log.debug(
      'Registered extension',
      attributes: {
        'namespace': extension.namespace,
        'functions': extension.functions.length,
      },
    );
  }

  /// Wires all extensions to [bridge], calls [MontyExtension.onAttach] for
  /// each, registers introspection builtins, and registers [extraFunctions]
  /// under the `'extra'` category. [MontyExtension.onAttach] errors are
  /// collected and thrown together as a single [StateError] after all
  /// extensions are processed.
  ///
  /// ## OS registration
  ///
  /// If any extensions return a non-null [MontyExtension.osContribution], their
  /// prefix maps are merged (overlapping prefixes throw [StateError]) and
  /// composed with [baseOs] as the fallback. The composed handler is then
  /// registered on [bridge] via `registerOs`. If there are no contributions
  /// and [baseOs] is non-null, [baseOs] is registered directly.
  ///
  /// ## Coordinator injection
  ///
  /// [coordinatorOf] returns this coordinator for each extension before
  /// [MontyExtension.onAttach] is called, so extensions that spawn children
  /// can reach for it from inside [MontyExtension.onAttach].
  Future<void> attachTo(
    MontyBridge bridge, {
    List<HostFunction>? extraFunctions,
    bool enableIntrospection = true,
    OsHandler? baseOs,
  }) async {
    if (_attached) {
      throw StateError(
        'ExtensionCoordinator.attachTo() has already been called. '
        'Create a new ExtensionCoordinator for a different bridge.',
      );
    }

    _log = bridge.logger.child('coordinator');

    _checkSupportedBackends(_extensions, _log);

    // Descending priority, registration order among equals: the index
    // breaks ties, as List.sort is not stable. High-priority extensions
    // attach first and dispose last.
    final ranked = [..._extensions.indexed]
      ..sort((a, b) {
        final byPriority = b.$2.priority.compareTo(a.$2.priority);

        return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
      });
    final attachOrder = [for (final (_, ext) in ranked) ext];
    _attachOrder = attachOrder;

    // Inject coordinator before onAttach so extensions that spawn children
    // (e.g. SandboxExtension) can reach it during lifecycle hooks.
    _injectCoordinators(attachOrder, this);

    _attachExtensionFunctions(attachOrder, bridge);
    _logExtensionsRegistered(attachOrder, _log);
    final contributions = _collectOsContributions(attachOrder);
    _osContributions = contributions;
    _baseOs = baseOs;
    _applyOsContributions(bridge, contributions, baseOs);
    if (extraFunctions != null && extraFunctions.isNotEmpty) {
      _attachExtraFunctions(extraFunctions, bridge, _log);
    }

    final errors = await _runExtensionOnAttaches(attachOrder, bridge, _log);

    if (enableIntrospection) {
      for (final fn in buildIntrospectionFunctions(bridge)) {
        bridge.register(fn, category: introspectionCategory);
      }
    }

    if (errors.isNotEmpty) {
      // Clean up partially-attached extensions before throwing.
      await disposeAll();
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError(
        '${errors.length} extension(s) failed to attach: $summary',
      );
    }

    _attached = true;
    _log.info(
      'Attached extensions to bridge',
      attributes: {'extensionCount': _extensions.length},
    );
  }

  /// Disposes all extensions in reverse registration order.
  ///
  /// All extensions are disposed even if some throw — errors are collected and
  /// thrown as a single [StateError] after all extensions have been disposed.
  /// Safe to call multiple times — each extension's [MontyExtension.onDispose]
  /// must be idempotent.
  Future<void> disposeAll() async {
    final errors = <(String, Object)>[];
    // Reverse registration order so later-registered extensions dispose first.
    final disposeOrder = (_attachOrder ?? _extensions).reversed;
    for (final ext in disposeOrder) {
      try {
        await ext.onDispose();
      } on Object catch (e) {
        _log.warning(
          'Extension dispose failed',
          attributes: {'namespace': ext.namespace, 'error': '$e'},
        );
        errors.add((ext.namespace, e));
      }
    }
    if (errors.isNotEmpty) {
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError(
        '${errors.length} extension(s) failed to dispose: $summary',
      );
    }
  }

  /// Builds a child [ExtensionCoordinator] seeded from this (parent)
  /// coordinator and attaches it to [bridge].
  ///
  /// Every parent extension contributes to the child according to its
  /// [MontyExtension.childPolicy] — `clone` invokes
  /// [MontyExtension.createChildInstance] for a fresh instance, `inherit`
  /// re-registers the parent instance, and `exclude` skips the extension
  /// entirely. The resulting coordinator is attached to [bridge] with an OS
  /// handler confined to the supplied workspace.
  ///
  /// Non-`Path.` OS prefixes (e.g., `os.`, `date.`, `datetime.`) are
  /// forwarded to the parent unchanged, and the parent's [attachTo] `baseOs`
  /// is used as the child's fallback for any unclaimed prefix.
  ///
  /// Throws [StateError] if [attachTo] has not yet been called on this
  /// coordinator — there is no parent OS state to inherit from.
  Future<ExtensionCoordinator> spawnChild({
    required ChildSpawnContext context,
    required MontyBridge bridge,
    Workspace? workspace,
    OsHandler? baseOs,
  }) async {
    if (!_attached) {
      throw StateError(
        'ExtensionCoordinator.spawnChild() called before attachTo(). '
        'A parent coordinator must be attached before spawning children.',
      );
    }

    final child = ExtensionCoordinator();
    // The clones made so far; a failure part-way disposes them.
    final clones = <MontyExtension>[];
    try {
      for (final ext in _extensions) {
        switch (ext.childPolicy) {
          case ChildPolicy.exclude:
            continue;
          case ChildPolicy.inherit:
            child.register(ext);
          case ChildPolicy.clone:
            final instance = ext.createChildInstance(context);
            assert(
              !identical(instance, ext),
              'createChildInstance() must return a new instance, not `this`. '
              'Use ChildPolicy.inherit if the extension should be shared.',
            );
            clones.add(instance);
            child.register(instance);
        }
      }
    } on Object {
      await _disposeQuietly(clones);
      rethrow;
    }

    final childWorkspace = workspace ?? Workspace();
    final childBaseOs = _composeChildBaseOs(
      childWorkspace,
      baseOsOverride: baseOs,
    );
    await child.attachTo(bridge, baseOs: childBaseOs);
    bridge.registerOs(
      childWorkspace.compose(
        composeOsHandlers(
          child._osContributions ?? {},
          fallback: childBaseOs,
        ),
      ),
    );

    return child;
  }

  /// Disposes [made], in reverse, logging each failure.
  Future<void> _disposeQuietly(List<MontyExtension> made) async {
    for (final ext in made.reversed) {
      try {
        await ext.onDispose();
      } on Object catch (e) {
        _log.warning(
          'Extension dispose failed',
          attributes: {'namespace': ext.namespace, 'error': '$e'},
        );
      }
    }
  }

  /// Child filesystem calls never reach the parent's fallback.
  OsHandler _composeChildBaseOs(
    Workspace workspace, {
    OsHandler? baseOsOverride,
  }) {
    final nonFilesystem = composeOsHandlers({
      for (final entry in (_osContributions ?? <String, OsHandler>{}).entries)
        if (entry.key != 'Path.' && entry.key != 'open') entry.key: entry.value,
    }, fallback: baseOsOverride ?? _baseOs);

    return workspace.compose(nonFilesystem);
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

  void _checkFunctionCollisions(MontyExtension extension) {
    final prefix = '${extension.namespace}_';
    final seen = <String>{};
    for (final fn in extension.functions) {
      final name = fn.schema.name;
      if (!name.startsWith(prefix)) {
        throw ArgumentError(
          'Function "$name" in extension "${extension.namespace}" must be '
          'prefixed with "$prefix".',
        );
      }
      if (!seen.add(name)) {
        throw ArgumentError(
          'Extension "${extension.namespace}" declares duplicate '
          'function "$name".',
        );
      }
      if (_functionNames.contains(name)) {
        throw StateError(
          'Function "$name" from extension "${extension.namespace}" conflicts '
          'with an already registered function.',
        );
      }
    }
  }
}
