import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/extensions/sandbox.dart';
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
  Set<MontyExtension> borrowed,
) {
  for (final ext in attachOrder) {
    if (!borrowed.contains(ext)) {
      ext.logger = bridge.logger.child(ext.namespace);
    }
    for (final fn in ext.functions) {
      bridge.register(fn, category: ext.namespace);
    }
  }
}

/// Rejects unsupported extension backends before lifecycle hooks run.
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

/// Logs each registered extension and its supported backends.
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

/// Attaches extensions in order and collects every failure.
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

/// Records each extension's most recent coordinator.
final Expando<ExtensionCoordinator> _owners = Expando('coordinator');

/// Returns the coordinator that last attached an extension.
ExtensionCoordinator coordinatorOf(MontyExtension extension) =>
    _owners[extension] ??
    (throw StateError(
      'Extension "${extension.namespace}" is not attached to a runtime.',
    ));

/// Records extension ownership before attachment hooks run.
void _injectCoordinators(
  List<MontyExtension> attachOrder,
  ExtensionCoordinator coordinator,
) {
  for (final ext in attachOrder) {
    _owners[ext] = coordinator;
  }
}

/// Collects OS contributions while rejecting duplicate prefixes.
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

/// Registers composed OS contributions with an optional fallback.
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

/// Coordinates validated extension registration, attachment, children, and
/// disposal.
class ExtensionCoordinator {
  final List<MontyExtension> _extensions = [];
  List<MontyExtension>? _attachOrder;
  final Set<String> _namespaces = {};
  final Set<String> _functionNames = {};
  BridgeLogger _log = BridgeLogger.silent;
  bool _attached = false;
  final Set<MontyExtension> _borrowed = Set.identity();
  final Map<MontyExtension, int> _leases = Map.identity();
  final Map<MontyExtension, Completer<void>> _leaseWaiters = Map.identity();
  final List<void Function()> _releaseLeases = [];
  Future<void>? _disposing;

  /// Retains extension OS contributions for child workspace composition.
  Map<String, OsHandler>? _osContributions;

  /// Retains the parent OS fallback for child composition.
  OsHandler? _baseOs;

  static final RegExp _validNamespace = RegExp(r'^[a-z][a-z0-9_]*$');
  static const int _maxNamespaceLength = 32;
  static const Set<String> _reservedNamespaces = {'introspection', 'extra'};

  /// Registered extensions in insertion order (unmodifiable).
  // ignore: unnecessarily-public-code, internal coordinator tests inspect ownership.
  List<MontyExtension> get extensions => UnmodifiableListView(_extensions);

  /// Registers an extension after namespace and function-name validation.
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

  /// Attaches registered extensions and composes their host and OS
  /// capabilities.
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
    final owned = attachOrder.where((ext) => !_borrowed.contains(ext)).toList();
    _injectCoordinators(owned, this);

    _attachExtensionFunctions(attachOrder, bridge, _borrowed);
    _logExtensionsRegistered(attachOrder, _log);
    final contributions = _collectOsContributions(attachOrder);
    _osContributions = contributions;
    _baseOs = baseOs;
    _applyOsContributions(bridge, contributions, baseOs);
    if (extraFunctions != null && extraFunctions.isNotEmpty) {
      _attachExtraFunctions(extraFunctions, bridge, _log);
    }

    final errors = await _runExtensionOnAttaches(
      owned,
      bridge,
      _log,
    );

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

  /// Disposes owned sandbox extensions first, then other owned extensions, and
  /// combines failures.
  Future<void> disposeAll() => _disposing ??= _disposeAll();

  /// Attaches a child coordinator under parent policy and workspace isolation.
  Future<ExtensionCoordinator> spawnChild({
    required ChildSpawnContext context,
    required MontyBridge bridge,
    // ignore: unnecessary-nullable-parameters, unnecessary-optional-parameters, standalone coordinator tests omit workspace.
    Workspace? workspace,
    OsHandler? baseOs,
  }) async {
    if (!_attached || _disposing != null) {
      throw StateError(
        'ExtensionCoordinator.spawnChild() called before attachTo(). '
        'A parent coordinator must be attached before spawning children.',
      );
    }

    final child = ExtensionCoordinator();
    // Registration may reject a fresh clone before the child owns it.
    MontyExtension? pendingClone;

    try {
      for (final ext in _extensions) {
        switch (ext.childPolicy) {
          case ChildPolicy.exclude:
            continue;
          case ChildPolicy.inherit:
            _borrowInstance(ext, child);
          case ChildPolicy.clone:
            final instance = ext.createChildInstance(context);
            assert(
              !identical(instance, ext),
              'createChildInstance() must return a new instance, not `this`. '
              'Use ChildPolicy.inherit if the extension should be shared.',
            );

            pendingClone = instance;
            child.register(instance);
            pendingClone = null;
        }
      }
    } on Object {
      await child._disposeFailedSpawn(pendingClone);
      rethrow;
    }

    final childWorkspace = workspace ?? Workspace();
    final childBaseOs = _composeChildBaseOs(
      childWorkspace,
      baseOsOverride: baseOs,
    );
    await child._attachChildTo(bridge, childBaseOs);
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

  Future<void> _disposeFailedSpawn(MontyExtension? pendingClone) async {
    // `register` can fail while producing its diagnostic log after the clone
    // has been added. In that case, `disposeAll` below owns its cleanup.
    final isOwned =
        pendingClone != null &&
        _extensions.any((extension) => identical(extension, pendingClone));
    if (!isOwned) {
      try {
        await pendingClone?.onDispose();
      } on Object {
        /* Preserve the registration error and continue cleaning up. */
      }
    }
    try {
      await disposeAll();
    } on Object {
      /* Preserve the factory or registration error. */
    }
  }

  Future<void> _attachChildTo(MontyBridge bridge, OsHandler baseOs) async {
    try {
      await attachTo(bridge, baseOs: baseOs);
    } on Object {
      try {
        await disposeAll();
      } on Object {
        /* preserve attachment error */
      }
      rethrow;
    }
  }

  void _borrowInstance(MontyExtension ext, ExtensionCoordinator child) {
    final owner = coordinatorOf(ext);
    if (owner._disposing != null) {
      throw StateError('Extension owner is disposing');
    }
    child.register(ext);
    child._borrowed.add(ext);
    owner._leases[ext] = (owner._leases[ext] ?? 0) + 1;
    child._releaseLeases.add(() {
      final left = owner._leases[ext]! - 1;
      owner._leases[ext] = left;
      if (left == 0) owner._leaseWaiters.remove(ext)?.complete();
    });
  }

  Future<void> _disposeAll() async {
    final errors = <(String, Object)>[];
    // Reverse registration order so later-registered extensions dispose first.
    final disposeOrder = (_attachOrder ?? _extensions).reversed;
    final owned = disposeOrder
        .where((ext) => !_borrowed.contains(ext))
        .toList();
    Future<void> dispose(MontyExtension ext) async {
      try {
        if ((_leases[ext] ?? 0) > 0) {
          await (_leaseWaiters[ext] ??= Completer<void>()).future;
        }
        await ext.onDispose();
      } on Object catch (e) {
        try {
          _log.warning(
            'Extension dispose failed',
            attributes: {'namespace': ext.namespace, 'error': '$e'},
          );
        } on Object {
          /* Continue disposing even when a logging sink fails. */
        }
        errors.add((ext.namespace, e));
      }
    }

    // Sandbox teardown settles admitted transfers and releases child/workspace
    // leases. Captured OS providers must remain alive until that finishes,
    // regardless of registration order or attachment priority.
    await Future.wait(owned.whereType<SandboxExtension>().map(dispose));
    await Future.wait(
      owned.where((ext) => ext is! SandboxExtension).map(dispose),
    );
    for (final release in _releaseLeases) {
      release();
    }
    _releaseLeases.clear();
    if (errors.isNotEmpty) {
      final summary = errors.map((e) => '${e.$1}: ${e.$2}').join('; ');
      throw StateError(
        '${errors.length} extension(s) failed to dispose: $summary',
      );
    }
  }

  /// Child filesystem calls never reach the parent's fallback.
  OsHandler _composeChildBaseOs(
    Workspace workspace, {
    required OsHandler? baseOsOverride,
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
