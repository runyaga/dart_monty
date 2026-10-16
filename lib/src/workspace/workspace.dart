// Internal workspace policy. Only core's public library crosses the boundary.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;

part 'workspace_transfers.dart';

/// Private memory backing retained until its admitted collections settle.
final class Workspace {
  /// Builds an independent namespace; seed bytes do not count as guest writes.
  Workspace({
    Map<String, Object> files = const {},
    Set<String> directories = const {},
    Set<String> readOnly = const {},
    int? writeBytesLimit = 8388608,
    int? memoryUsageLimit = 8388608,
    OsHandler? parent,
  }) : _writeLimit = writeBytesLimit,
       _memoryLimit = memoryUsageLimit,
       _parent = parent,
       _protected = readOnly.map(_childPath).toSet() {
    _validateCap(writeBytesLimit);
    _validateCap(memoryUsageLimit);
    final entries = <String, Uint8List?>{'/work': null};
    for (final dir in directories) {
      _addParents(entries, '${_childPath(dir)}/_');
    }
    for (final file in files.entries) {
      final path = _childPath(file.key);
      if (path == '/work') {
        throw _transferError('regular file cannot replace workspace root');
      }
      _addParents(entries, path);
      entries[path] = switch (file.value) {
        final String text => Uint8List.fromList(utf8.encode(text)),
        final Uint8List bytes => Uint8List.fromList(bytes),
        _ => throw ArgumentError('Workspace content must be text or bytes'),
      };
    }
    _memoryUsage = _size(entries);
    _checkMemory(_memoryUsage);
    _access = _fromEntries(entries);
  }

  /// Cumulative accepted guest payload ceiling; null explicitly opts out.
  final int? _writeLimit;

  /// Retained content plus 64 bytes per workspace entry; null opts out.
  final int? _memoryLimit;
  OsHandler? _parent;
  final Set<String> _protected;
  OSAccess _access = OSAccess();
  int _writeBytes = 0;
  int _memoryUsage = 0;
  bool _freeing = false;
  bool _leased = false;
  Completer<void>? _leaseDone;
  Future<void>? _disposal;

  /// Accepted payload bytes across feeds, never refunded by deletion.
  // ignore: unnecessarily-public-code, real-session tests inspect this internal policy boundary.
  int get writeBytes => _writeBytes;

  /// Retained logical bytes, including /work itself but not OSAccess's root.
  // ignore: unnecessarily-public-code, real-session tests inspect this internal policy boundary.
  int get memoryUsage => _memoryUsage;

  /// Routes filesystem calls exclusively here and other calls to contributions.
  OsHandler compose(OsHandler nonFilesystem) => (name, args, kwargs) {
    if (_filesystem(name)) return call(name, args, kwargs);

    return nonFilesystem(name, args, kwargs);
  };

  /// Synchronous routing is essential: an asynchronous throw is not a decline.
  // ignore: unnecessarily-public-code, real-session tests inspect this internal policy boundary.
  MontyValue call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    if (_freeing && !_leased) throw StateError('Workspace is disposed');
    if (!_filesystem(name)) throw const OsCallNotHandledException();
    final path = _operationPath(args.firstOrNull);
    if (!_inside(path)) throw const OsCallNotHandledException();
    final target = name == 'Path.rename'
        ? _operationPath(args.elementAtOrNull(1))
        : null;
    if (target != null && !_inside(target)) {
      throw const OsCallNotHandledException();
    }
    final normalized = <MontyValue>[
      MontyPath(path),
      if (target != null) MontyPath(target) else ...args.skip(1),
    ];
    if (!_mutates(name, args)) {
      return _sync(_access, name, normalized, kwargs);
    }

    return _mutate(name, normalized, kwargs, path, target);
  }

  /// Refuses new leases immediately; admitted collection may finish its writes.
  Future<void> dispose() {
    _freeing = true;

    return _disposal ??= _finishDisposal();
  }

  MontyValue _mutate(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
    String path,
    String? target,
  ) {
    if (_leased) throw StateError('Workspace is being collected');
    _checkProtected(path);
    if (target != null) _checkProtected(target);
    final payload = _payload(name, args);
    final nextWrites = _writeBytes + payload;
    final writeCap = _writeLimit;
    if (writeCap != null && nextWrites > writeCap) {
      throw const ExternalException(
        'OSError',
        'Workspace write byte limit exceeded',
      );
    }
    if (target != null && p.posix.isWithin(path, target)) {
      throw const ExternalException(
        'OSError',
        'Cannot rename into a descendant',
      );
    }

    // Mutations are synchronous and serialized. Prepare a private candidate
    // from current public namespace reads (never OSAccess.files paths). Core
    // failures, including partially applied directory operations, discard it.
    // No live namespace or counter changes until both caps accept the result.
    final candidate = _fromEntries(_snapshot(_access));
    final result = _sync(candidate, name, args, kwargs);
    final retained = _size(_snapshot(candidate));
    _checkMemory(retained);
    _access = candidate;
    _memoryUsage = retained;
    _writeBytes = nextWrites;

    return result;
  }

  void _checkProtected(String path) {
    if (_protected.any(
      (root) =>
          root == path ||
          p.posix.isWithin(root, path) ||
          p.posix.isWithin(path, root),
    )) {
      throw ExternalException(
        'PermissionError',
        "[Errno 30] Read-only file system: '$path'",
      );
    }
  }

  void _checkMemory(int retained) {
    final memoryCap = _memoryLimit;
    if (memoryCap != null && retained > memoryCap) {
      throw const ExternalException(
        'MemoryError',
        'Workspace memory limit exceeded',
      );
    }
  }

  void _lease() {
    if (_freeing) throw StateError('Workspace is disposed');
    if (_leased) throw StateError('Workspace is being collected');
    _leased = true;
    _leaseDone = Completer<void>();
  }

  void _release() {
    _leased = false;
    _leaseDone?.complete();
    _leaseDone = null;
  }

  Future<void> _finishDisposal() async {
    await _leaseDone?.future;
    _access = OSAccess();
    _parent = null;
    _protected.clear();
    _memoryUsage = 0;
    _writeBytes = 0;
  }
}

void _validateCap(int? cap) {
  if (cap != null && cap < 0) {
    throw ArgumentError.value(cap, 'cap', 'must be nonnegative');
  }
}

/// Validates a guest reduction without converting explicit host null to
/// default.
int? reduceWorkspaceCap(int? host, int? guest) {
  _validateCap(host);
  _validateCap(guest);
  if (guest != null && host != null && guest > host) {
    throw ArgumentError('Workspace caps can only reduce the configured limit');
  }

  return guest ?? host;
}

bool _filesystem(String name) => name == 'open' || name.startsWith('Path.');
bool _inside(String path) => path == '/work' || path.startsWith('/work/');
String _operationPath(MontyValue? value) {
  final text = switch (value) {
    MontyString(:final value) || MontyPath(:final value) => value,
    MontyFileHandle(:final path) => path,
    _ => throw const ExternalException('TypeError', 'Expected a path'),
  };

  return p.posix.normalize(text);
}

const _mutatingCalls = {
  'Path.write_text',
  'Path.write_bytes',
  'Path.append_text',
  'Path.append_bytes',
  'Path.mkdir',
  'Path.unlink',
  'Path.rmdir',
  'Path.rename',
};

bool _mutates(String name, List<MontyValue> args) {
  if (_mutatingCalls.contains(name)) return true;
  if (name != 'open') return false;
  final mode = args.elementAtOrNull(1);

  return mode is MontyString && ['w', 'a', 'x', '+'].any(mode.value.contains);
}

int _payload(String name, List<MontyValue> args) {
  if (!name.startsWith('Path.write_') && !name.startsWith('Path.append_')) {
    return 0;
  }

  return switch (args.elementAtOrNull(1)) {
    MontyString(:final value) => utf8.encode(value).length,
    MontyBytes(:final value) => value.length,
    _ => throw const ExternalException('TypeError', 'Expected text or bytes'),
  };
}

MontyValue _sync(
  OSAccess access,
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => access.call(name, args, kwargs) as MontyValue;

Map<String, Uint8List?> _snapshot(OSAccess access) {
  final entries = <String, Uint8List?>{};
  void visit(String path) {
    final args = [MontyPath(path)];
    if (_sync(access, 'Path.is_dir', args, {}) == const MontyBool(true)) {
      entries[path] = null;
      final children = _sync(access, 'Path.iterdir', args, {}) as MontyList;
      for (final child in children.items) {
        visit(_operationPath(child));
      }
    } else {
      final bytes = _sync(access, 'Path.read_bytes', args, {}) as MontyBytes;
      entries[path] = Uint8List.fromList(bytes.value);
    }
  }

  if (_sync(access, 'Path.exists', [MontyPath('/work')], {}) ==
      const MontyBool(true)) {
    visit('/work');
  }

  return entries;
}

int _size(Map<String, Uint8List?> entries) =>
    entries.values.fold(0, (sum, content) => sum + 64 + (content?.length ?? 0));

void _addParents(Map<String, Uint8List?> entries, String path) {
  var parent = p.posix.dirname(path);
  while (_inside(parent)) {
    if (entries[parent] != null) {
      throw ArgumentError('Conflicting workspace paths');
    }
    entries[parent] = null;
    parent = p.posix.dirname(parent);
  }
}

OSAccess _fromEntries(Map<String, Uint8List?> entries) {
  final access = OSAccess(
    files: [
      for (final e in entries.entries)
        if (e.value case final bytes?) MemoryFile(e.key, bytes),
    ],
  );
  for (final e in entries.entries) {
    if (e.value == null) {
      _sync(
        access,
        'Path.mkdir',
        [MontyPath(e.key)],
        {
          'parents': const MontyBool(true),
          'exist_ok': const MontyBool(true),
        },
      );
    }
  }

  return access;
}
