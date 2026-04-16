import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';
import 'package:dart_monty/src/bridge/bridge/host_param.dart';
import 'package:dart_monty/src/bridge/bridge/host_param_type.dart';
import 'package:dart_monty/src/bridge/bridge/monty_bridge.dart';
import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:signals_core/signals_core.dart';

/// Plugin for persistent or in-memory key-value storage.
class StoragePlugin extends MontyPlugin {
  /// Creates a [StoragePlugin].
  StoragePlugin({
    StorageBackend? backend,
    this.scope = 'default',
  }) : _backend = backend ?? MemoryStorageBackend();

  /// The storage scope for this plugin instance.
  final String scope;

  /// Reactive list of all keys currently in the store.
  final ReadonlySignal<List<String>> storageSignal = signal(const []);

  final StorageBackend _backend;

  /// Internal writable signal for storage keys.
  Signal<List<String>> get _storageSignal =>
      storageSignal as Signal<List<String>>;

  @override
  String get namespace => 'storage';

  @override
  String? get systemPromptContext =>
      'Key-value storage. Use storage_get/set. Path /storage/ is also '
      'mapped to this backend.';

  @override
  Map<String, OsProvider>? get osContribution => {
    'Path.': StorageFsOsProvider(backend: _backend, onUpdate: _updateSignal),
  };

  @override
  List<HostFunction> get functions => [
    HostFunction(schema: _storageGetSchema, handler: _handleGet),
    HostFunction(schema: _storageSetSchema, handler: _handleSet),
    HostFunction(schema: _storageDeleteSchema, handler: _handleDelete),
    HostFunction(schema: _storageListSchema, handler: _handleList),
    HostFunction(schema: _storageHasSchema, handler: _handleHas),
    HostFunction(schema: _storageClearSchema, handler: _handleClear),
  ];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    await super.onRegister(bridge);
    await _updateSignal();
  }

  @override
  MontyPlugin? createChildInstance({ChildSpawnContext? context}) {
    // Children share the same backend and scope by default.
    return StoragePlugin(backend: _backend, scope: scope);
  }

  @override
  Future<void> onDispose() async {
    await _backend.dispose();
    await super.onDispose();
  }

  Future<void> _updateSignal() async {
    _storageSignal.value = await _backend.list();
  }

  Future<Object?> _handleGet(Map<String, Object?> args) {
    return _backend.get(args['key']! as String);
  }

  Future<Object?> _handleSet(Map<String, Object?> args) async {
    final value = args['value'];
    if (value != null &&
        value is! String &&
        value is! Uint8List &&
        value is! num &&
        value is! bool) {
      throw ArgumentError(
        'StoragePlugin v1 only supports primitive types, String, or Uint8List.',
      );
    }
    await _backend.set(args['key']! as String, value);
    await _updateSignal();

    return null;
  }

  Future<Object?> _handleDelete(Map<String, Object?> args) async {
    await _backend.delete(args['key']! as String);
    await _updateSignal();

    return null;
  }

  Future<Object?> _handleList(Map<String, Object?> args) {
    return _backend.list();
  }

  Future<Object?> _handleHas(Map<String, Object?> args) async {
    final list = await _backend.list();

    return list.contains(args['key']);
  }

  Future<Object?> _handleClear(Map<String, Object?> args) async {
    await _backend.clear();
    unawaited(_updateSignal());

    return null;
  }
}

/// Minimal interface for a key-value storage backend.
abstract interface class StorageBackend {
  /// Retrieves the value associated with [key].
  Future<Object?> get(String key);

  /// Sets the [value] for [key].
  Future<void> set(String key, Object? value);

  /// Deletes the entry for [key].
  Future<void> delete(String key);

  /// Returns a list of all keys currently in the store.
  Future<List<String>> list();

  /// Deletes all entries from the store.
  Future<void> clear();

  /// Closes the backend and releases any resources.
  Future<void> dispose();
}

/// In-memory storage backend.
class MemoryStorageBackend implements StorageBackend {
  final Map<String, Object?> _data = {};

  @override
  Future<Object?> get(String key) async => _data[key];

  @override
  Future<void> set(String key, Object? value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<List<String>> list() async => _data.keys.toList();

  @override
  Future<void> clear() async => _data.clear();

  @override
  Future<void> dispose() async => _data.clear();
}

/// OsProvider that maps /storage/ path operations to a [StorageBackend].
class StorageFsOsProvider extends OsProvider {
  /// Creates a [StorageFsOsProvider].
  // ignore: prefer-declaring-const-constructor, backend is not const
  StorageFsOsProvider({required this.backend, this.onUpdate}) : super.base();

  /// The backend to use for storage operations.
  final StorageBackend backend;

  /// Optional callback invoked when the storage is modified via VFS.
  final Future<void> Function()? onUpdate;

  @override
  Future<Object?> resolve(MontyOsCall call) async {
    // Only intercept calls that target the /storage/ prefix.
    final path = _extractPath(call);
    if (path == null || !path.startsWith('/storage/')) {
      return null; // Fall through to next provider
    }

    final key = path.substring(9); // remove /storage/

    return switch (call.operationName) {
      'Path.read_text' => await backend.get(key),
      'Path.write_text' => () async {
        await backend.set(key, _extractArg(call, 'contents'));
        await onUpdate?.call();

        return null;
      }(),
      'Path.unlink' => () async {
        await backend.delete(key);
        await onUpdate?.call();

        return null;
      }(),
      'Path.exists' || 'Path.is_file' => (await backend.list()).contains(key),
      _ => null,
    };
  }

  String? _extractPath(MontyOsCall call) {
    // Standard Path.* calls pass the path as the first positional argument.
    final first = call.arguments.firstOrNull;
    if (first is MontyString) return first.value;

    // Check kwargs just in case.
    final path = call.kwargs?['path'];
    if (path is MontyString) return path.value;

    return null;
  }

  Object? _extractArg(MontyOsCall call, String name) {
    final val = call.kwargs?[name];
    if (val != null) return _toDart(val);

    // For write_text(contents), it's often the second positional arg (after
    // self/path).
    if (name == 'contents') {
      final second = call.arguments.elementAtOrNull(1);
      if (second != null) return _toDart(second);
    }

    return null;
  }

  Object? _toDart(MontyValue val) {
    return switch (val) {
      MontyString(:final value) => value,
      MontyInt(:final value) => value,
      MontyFloat(:final value) => value,
      MontyBool(:final value) => value,
      MontyBytes(:final value) => value,
      _ => null,
    };
  }
}

// ---------------------------------------------------------------------------
// Schemas
// ---------------------------------------------------------------------------

const _storageGetSchema = HostFunctionSchema(
  name: 'storage_get',
  description: 'Get a value by key.',
  params: [
    HostParam(name: 'key', type: HostParamType.string, description: 'Key.'),
  ],
);

const _storageSetSchema = HostFunctionSchema(
  name: 'storage_set',
  description: 'Set a value for a key.',
  params: [
    HostParam(name: 'key', type: HostParamType.string, description: 'Key.'),
    HostParam(
      name: 'value',
      type: HostParamType.any,
      description: 'Value (String, number, bool, or bytes).',
    ),
  ],
);

const _storageDeleteSchema = HostFunctionSchema(
  name: 'storage_delete',
  description: 'Delete a key.',
  params: [
    HostParam(name: 'key', type: HostParamType.string, description: 'Key.'),
  ],
);

const _storageListSchema = HostFunctionSchema(
  name: 'storage_list',
  description: 'List all keys.',
);

const _storageHasSchema = HostFunctionSchema(
  name: 'storage_has',
  description: 'Check if a key exists.',
  params: [
    HostParam(name: 'key', type: HostParamType.string, description: 'Key.'),
  ],
);

const _storageClearSchema = HostFunctionSchema(
  name: 'storage_clear',
  description: 'Clear all storage.',
);
