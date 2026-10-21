import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;

/// Transfers bounded content through explicitly captured persistent mounts.
final class PersistentTransfer {
  /// Captures immutable mount modes and refuses overlay paths before checkout.
  PersistentTransfer(Monty pool, List<MountDir> mounts)
    : _pool = pool,
      _mounts = List.unmodifiable(mounts);

  /// Pool owned by the calling workspace.
  final Monty _pool;

  /// Explicit captured capabilities, never the suspended session table.
  final List<MountDir> _mounts;

  /// Uses fixed code and typed inputs without feeding the suspended parent
  /// session.
  Future<MontyValue> call(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) async {
    final normalized = _checkedTransferPath(args.firstOrNull, _mounts);
    final code = _operations[name];
    if (code == null) throw const OsCallNotHandledException();
    _checkWritable(name, normalized);
    final session = await _checkout();
    try {
      return await session.feedRun(
        'from pathlib import Path\n$code',
        inputs: {
          'path': MontyString(normalized),
          'data': args.elementAtOrNull(1) ?? const MontyNone(),
          'parents': kwargs['parents'] ?? const MontyBool(false),
          'exist_ok': kwargs['exist_ok'] ?? const MontyBool(false),
        },
        mount: _mounts,
      );
    } finally {
      await session.close();
    }
  }

  void _checkWritable(String name, String path) {
    if ((name.startsWith('Path.write_') ||
            name.startsWith('Path.append_') ||
            name == 'Path.mkdir') &&
        _mounts.any(
          (mount) =>
              mount.mode == 'read-only' &&
              (path == mount.virtualPath ||
                  p.posix.isWithin(mount.virtualPath, path)),
        )) {
      throw ExternalException(
        'PermissionError',
        "[Errno 30] Read-only file system: '$path'",
      );
    }
  }

  Future<MontySession> _checkout() async {
    final checkout = _pool.checkout(
      limits: const ResourceLimits(
        maxFeedDuration: Duration(seconds: 5),
        maxTurnDuration: Duration(seconds: 2),
        maxMemory: 33554432,
        maxSuspensions: 16384,
        maxTotalSleep: Duration.zero,
      ),
    );
    try {
      return await checkout.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      unawaited(_closeLate(checkout));
      rethrow;
    }
  }
}

const _operations = {
  'Path.stat': 'Path(path).stat()',
  'Path.is_symlink': 'Path(path).is_symlink()',
  'Path.write_bytes': 'Path(path).write_bytes(data)',
  'Path.write_text': 'Path(path).write_text(data)',
  'Path.append_text': '''
file = open(path, 'a')
result = file.write(data)
file.close()
result''',
  'Path.append_bytes': '''
file = open(path, 'ab')
result = file.write(data)
file.close()
result''',
  'Path.mkdir': 'Path(path).mkdir(parents=parents, exist_ok=exist_ok)',
};

Future<void> _closeLate(Future<MontySession> checkout) async {
  try {
    await (await checkout).close();
  } on Object {
    // The original acquisition failure is already delivered to the caller.
    return;
  }
}

String _checkedTransferPath(MontyValue? value, List<MountDir> mounts) {
  final path = switch (value) {
    MontyPath(:final value) || MontyString(:final value) => value,
    _ => throw const ExternalException('OSError', 'Expected absolute path'),
  };
  if (!p.posix.isAbsolute(path) ||
      path.contains('\x00') ||
      path.split('/').contains('..')) {
    throw const ExternalException('OSError', 'Expected absolute path');
  }
  final normalized = p.posix.normalize(path);
  final matching = mounts.where(
    (mount) =>
        normalized == mount.virtualPath ||
        p.posix.isWithin(mount.virtualPath, normalized),
  );
  if (matching.any((mount) => mount.mode == 'overlay')) {
    throw const ExternalException(
      'OSError',
      'Overlay transfer is unsupported',
    );
  }

  return normalized;
}
