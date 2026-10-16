part of 'workspace.dart';

const _transferBytes = 8388608;
const _transferEntries = 4096;
const _transferDepth = 32;
const _transferPath = 4096;

ExternalException _transferError(String detail) =>
    ExternalException('OSError', 'Workspace transfer: $detail');

String _checkedPath(String path, {required bool absolute}) {
  if (path.isEmpty ||
      path.contains('\x00') ||
      p.posix.isAbsolute(path) != absolute ||
      path.split('/').contains('..')) {
    throw _transferError(
      'expected ${absolute ? "absolute parent" : "relative child"} path',
    );
  }
  final normalized = p.posix.normalize(path);
  if (utf8.encode(normalized).length > _transferPath) {
    throw _transferError('path limit exceeded');
  }

  return normalized;
}

String _childPath(String path) {
  final relative = _checkedPath(path, absolute: false);
  if (relative == '.') return '/work';
  final result = '/work/$relative';
  if (utf8.encode(result).length > _transferPath) {
    throw _transferError('path limit exceeded');
  }

  return result;
}

/// Typed Python mapping validation, before checkout or retaining a request.
Map<String, String> workspaceMapping(MontyValue? value) {
  if (value == null || value is MontyNone) return {};
  if (value is! MontyDict) throw _transferError('expected a path mapping');
  final result = <String, String>{};
  for (final (key, destination) in value.pairs) {
    if (key is! MontyString || destination is! MontyString) {
      throw _transferError('path mappings require strings');
    }
    result[key.value] = destination.value;
  }

  return result;
}

void _disjoint(Iterable<String> paths) {
  final seen = <String>[];
  for (final path in paths) {
    if (seen.any(
      (other) =>
          other == path ||
          p.posix.isWithin(path, other) ||
          p.posix.isWithin(other, path),
    )) {
      throw _transferError('overlapping destinations');
    }
    seen.add(path);
  }
}

List<(String, String)> _mapping(Map<String, String> mapping) {
  if (mapping.length > _transferEntries) {
    throw _transferError('entry limit exceeded');
  }

  return [
    for (final e in mapping.entries)
      (_childPath(e.key), _checkedPath(e.value, absolute: true)),
  ];
}

/// Per-sandbox transfer admission: one staging buffer across copy and collect.
final class WorkspaceTransfers {
  Future<void> _tail = Future<void>.value();
  final Set<Object> _pending = {};
  bool _disposed = false;

  /// Stages every source before publishing an independent workspace.
  // Optional defaults are exercised directly by real-session policy tests.
  // ignore: unnecessary-optional-parameters
  Future<Workspace> copyIn({
    // ignore: unnecessary-optional-parameters, tests cover omission and defaults.
    OsHandler? parent,
    // ignore: unnecessary-optional-parameters, tests cover omission and defaults.
    Map<String, String> files = const {},
    // ignore: unnecessary-optional-parameters, tests cover omission and defaults.
    Map<String, String> roFiles = const {},
    // ignore: unnecessary-optional-parameters, tests cover omission and defaults.
    int? writeBytesLimit = 8388608,
    // ignore: unnecessary-optional-parameters, tests cover omission and defaults.
    int? memoryUsageLimit = 8388608,
  }) async {
    _validateCap(writeBytesLimit);
    _validateCap(memoryUsageLimit);
    final writable = _mapping(files);
    final readonly = _mapping(roFiles);
    final mappings = [...writable, ...readonly];
    if (mappings.length > _transferEntries) {
      throw _transferError('entry limit exceeded');
    }
    _disjoint(mappings.map((e) => e.$1));
    if (mappings.isNotEmpty && parent == null) {
      throw _transferError('missing live parent OS adapter');
    }

    return _run(Object(), () async {
      final stage = _Stage();
      for (final (child, source) in mappings) {
        await stage.read(parent ?? _missingParent, source, child);
      }

      return _copiedWorkspace(stage, readonly, parent, (
        writeBytesLimit,
        memoryUsageLimit,
      ));
    });
  }

  /// Collects through the captured parent callback; a failed write is
  /// retryable.
  Future<void> collect(Workspace workspace, Map<String, String> collect) async {
    if (workspace._freeing) throw StateError('Workspace is disposed');
    // Refuse a second request before copying or retaining its mapping.
    if (_pending.contains(workspace)) {
      throw StateError('Collection already pending');
    }
    final mappings = _mapping(collect);
    _disjoint(mappings.map((e) => e.$2));
    final parent = workspace._parent;
    if (mappings.isNotEmpty && parent == null) {
      throw _transferError('missing live parent OS adapter');
    }
    await _run(workspace, () async {
      workspace._lease();
      try {
        await _collect(workspace, parent ?? _missingParent, mappings);
      } finally {
        workspace._release();
      }
    });
  }

  /// Refuses queued transfers and waits for any admitted operation to settle.
  Future<void> dispose() async {
    _disposed = true;
    await _tail;
  }

  Future<void> _collect(
    Workspace workspace,
    OsHandler parent,
    List<(String, String)> mappings,
  ) async {
    final stage = _Stage();
    for (final (source, destination) in mappings) {
      await _noLinks(parent, destination);
      await stage.read(workspace.call, source, destination);
    }
    for (final entry in stage.entries) {
      await _noLinks(parent, entry.destination);
    }
    // All reads and destination validation have succeeded. Parent failures
    // may leave earlier writes, intentionally without rollback promises.
    for (final entry in stage.entries) {
      await parent(
        entry.bytes == null ? 'Path.mkdir' : 'Path.write_bytes',
        [
          MontyPath(entry.destination),
          if (entry.bytes case final bytes?) MontyBytes(bytes),
        ],
        entry.bytes == null
            ? {
                'parents': const MontyBool(true),
                'exist_ok': const MontyBool(true),
              }
            : {},
      );
    }
  }

  Future<T> _run<T>(Object key, Future<T> Function() operation) {
    if (_disposed) return Future.error(StateError('Transfers are disposed'));
    if (!_pending.add(key)) {
      return Future.error(StateError('Collection already pending'));
    }
    final previous = _tail;
    final finished = Completer<void>();
    _tail = finished.future;

    return (() async {
      try {
        await previous;
        if (_disposed) throw StateError('Transfers are disposed');

        return await operation();
      } finally {
        _pending.remove(key);
        finished.complete();
      }
    })();
  }
}

final class _StagedEntry {
  const _StagedEntry(this.destination, this.bytes);
  final String destination;
  final Uint8List? bytes;
}

Future<void> _noLinks(OsHandler handler, String path) async {
  var prefix = '/';
  for (final part
      in path.split('/').where((component) => component.isNotEmpty)) {
    prefix = p.posix.join(prefix, part);
    final result = await handler('Path.is_symlink', [MontyPath(prefix)], {});
    if (result != const MontyBool(false)) {
      throw _transferError('symlink or unverifiable path');
    }
  }
}

final class _Stage {
  final List<_StagedEntry> entries = [];
  int _bytes = 0;
  int _count = 0;
  final Set<(int, int)> _identities = {};

  Future<void> read(
    OsHandler source,
    String path,
    String destination, [
    int depth = 0,
  ]) async {
    _checkedPath(path, absolute: true);
    _checkedPath(destination, absolute: true);
    if (depth > _transferDepth) throw _transferError('depth limit exceeded');
    if (++_count > _transferEntries) {
      throw _transferError('entry limit exceeded');
    }
    await _noLinks(source, path);
    final stat = await source('Path.stat', [MontyPath(path)], {});
    if (stat is! MontyNamedTuple) throw _transferError('unknown source size');
    final mode = _statField(stat, 'st_mode') & 0xF000;
    if (mode == 0x4000) {
      await _directory(source, path, destination, depth, stat);

      return;
    }
    if (mode != 0x8000) throw _transferError('source is not a regular file');
    await _file(source, path, destination, stat);
  }

  Future<void> _directory(
    OsHandler source,
    String path,
    String destination,
    int depth,
    MontyNamedTuple stat,
  ) async {
    final identity = (_statField(stat, 'st_dev'), _statField(stat, 'st_ino'));
    if (identity.$2 != 0 && !_identities.add(identity)) {
      throw _transferError('repeated directory identity');
    }
    entries.add(_StagedEntry(destination, null));
    final listing = await source('Path.iterdir', [MontyPath(path)], {});
    if (listing is! MontyList ||
        listing.items.length > _transferEntries - _count) {
      throw _transferError('entry limit exceeded');
    }
    final seen = <String>{};
    for (final item in listing.items) {
      final child = _operationPath(item);
      if (p.posix.dirname(child) != path || !seen.add(child)) {
        throw _transferError('invalid directory listing');
      }
      await read(
        source,
        child,
        p.posix.join(destination, p.posix.basename(child)),
        depth + 1,
      );
    }
  }

  Future<void> _file(
    OsHandler source,
    String path,
    String destination,
    MontyNamedTuple stat,
  ) async {
    final reserved = _statField(stat, 'st_size');
    if (reserved < 0 || reserved > _transferBytes - _bytes) {
      throw _transferError('byte limit exceeded');
    }
    _bytes += reserved;
    final content = await source('Path.read_bytes', [MontyPath(path)], {});
    if (content is! MontyBytes || content.value.length > reserved) {
      throw _transferError('source grew beyond reservation');
    }
    entries.add(_StagedEntry(destination, Uint8List.fromList(content.value)));
  }
}

MontyValue _missingParent(
  String name,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => throw _transferError('missing live parent OS adapter');

int _statField(MontyNamedTuple stat, String name) {
  final index = stat.fieldNames.indexOf(name);
  final invalid = _transferError('unknown source metadata');
  if (index < 0) throw invalid;
  final value = stat.values.elementAtOrNull(index);
  if (value is! MontyInt) throw invalid;

  return value.value;
}

Workspace _copiedWorkspace(
  _Stage stage,
  List<(String, String)> readOnlyPaths,
  OsHandler? parent,
  (int?, int?) caps,
) {
  final (writeBytesLimit, memoryUsageLimit) = caps;

  return Workspace(
    files: {
      for (final entry in stage.entries)
        p.posix.relative(entry.destination, from: '/work'): ?entry.bytes,
    },
    directories: {
      for (final entry in stage.entries)
        if (entry.bytes == null)
          p.posix.relative(entry.destination, from: '/work'),
    },
    readOnly: {
      for (final (child, _) in readOnlyPaths)
        p.posix.relative(child, from: '/work'),
    },
    writeBytesLimit: writeBytesLimit,
    memoryUsageLimit: memoryUsageLimit,
    parent: parent,
  );
}
