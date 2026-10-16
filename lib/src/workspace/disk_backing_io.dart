import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_monty/src/workspace/disk_backing.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:path/path.dart' as p;

/// Creates owned backing, or refuses when native mounts are unavailable.
DiskBacking createDiskBacking(String base, Map<String, Uint8List?> entries) {
  final parent = Directory(base)..createSync(recursive: true);
  final root = Directory(parent.resolveSymbolicLinksSync()).createTempSync(
    'monty-',
  );
  final backing = _DiskBackingIo(root);
  try {
    for (final entry in entries.entries) {
      final host = backing._host(entry.key);
      if (entry.value case final bytes?) {
        final file = File(host);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes);
      } else {
        Directory(host).createSync(recursive: true);
      }
    }
    // Fail construction (and remove seeds) when delivery is incomplete.
    backing.open().close();

    return backing;
  } on Object {
    backing.dispose();
    rethrow;
  }
}

final class _DiskBackingIo implements DiskBacking {
  _DiskBackingIo(this.root)
    : canonical = p.join(root.resolveSymbolicLinksSync(), 'work'),
      _token = List.generate(
        32,
        (_) => Random.secure().nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join() {
    // The marker is outside the mounted namespace and cannot be guest-written.
    File(_marker).writeAsStringSync(_token, flush: true);
    Directory(canonical).createSync();
  }
  final Directory root;
  final String canonical;
  final String _token;
  bool _disposed = false;

  String get _marker => p.join(p.dirname(canonical), '.owner');

  @override
  Future<Monty> startTransferPool() => Monty.start(
    workerLocation: Platform.environment['DART_MONTY_WORKER'],
    minProcesses: 0,
    maxProcesses: 1,
    checkoutTimeout: const Duration(seconds: 5),
    requestTimeout: const Duration(seconds: 5),
  );

  @override
  void validate(String path) {
    if (FileSystemEntity.typeSync(canonical, followLinks: false) !=
            FileSystemEntityType.directory ||
        root.resolveSymbolicLinksSync() != p.dirname(canonical)) {
      throw const ExternalException('OSError', 'Workspace backing changed');
    }
    var host = canonical;
    for (final part in p.posix.relative(path, from: '/work').split('/')) {
      host = p.join(host, part);
      if (!p.equals(host, canonical) && !p.isWithin(canonical, host)) {
        throw const ExternalException('PermissionError', 'Outside workspace');
      }
      if (FileSystemEntity.typeSync(host, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const ExternalException('OSError', 'Workspace symlink refused');
      }
    }
  }

  @override
  bool sameHostEntry(String path, String other) {
    try {
      validate(path);
      validate(other);
      final left = _host(path);
      final right = _host(other);

      return FileSystemEntity.identicalSync(left, right);
    } on FileSystemException {
      return false;
    }
  }

  @override
  MountDir open({String mode = 'read-write'}) {
    validate('/work');

    return MountDir(
      hostPath: canonical,
      virtualPath: '/work',
      mode: mode,
    );
  }

  @override
  Future<Map<String, Uint8List?>> snapshot({
    required int maxBytes,
    Iterable<String> roots = const ['/work'],
    int maxEntries = 4096,
    int maxDepth = 32,
  }) async {
    final entries = <String, Uint8List?>{};
    var bytesLeft = maxBytes;
    var occurrences = 0;
    Future<void> visit(String path, int depth) async {
      validate(path);
      if (depth > maxDepth || ++occurrences > maxEntries) {
        throw const ExternalException('OSError', 'Workspace traversal limit');
      }
      final host = _host(path);
      final type = FileSystemEntity.typeSync(host, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        entries[path] = null;
        // Stream the listing: never materialize an unbounded listSync result.
        await for (final child in Directory(host).list(followLinks: false)) {
          await visit(p.posix.join(path, p.basename(child.path)), depth + 1);
        }
      } else if (type == FileSystemEntityType.file) {
        final bytes = _readBoundedFile(host, bytesLeft);
        bytesLeft -= bytes.length;
        entries[path] = bytes;
      } else {
        throw const ExternalException('OSError', 'Workspace special file');
      }
    }

    for (final source in roots) {
      await visit(source, 0);
    }

    return entries;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _deleteOwned(Directory(canonical));
    _validateCleanup(p.dirname(canonical));
    File(_marker).deleteSync();
    root.deleteSync();
    _disposed = true;
  }

  void _deleteOwned(Directory directory) {
    _validateCleanup(directory.path);
    for (final child in directory.listSync(followLinks: false)) {
      _validateCleanup(directory.path);
      if (child is Directory) {
        _deleteOwned(child);
      } else {
        // Link.delete and nonrecursive File.delete unlink the entry itself.
        child.deleteSync();
      }
    }
    _validateCleanup(directory.path);
    directory.deleteSync();
  }

  void _validateCleanup(String path) {
    final retained = ExternalException(
      'OSError',
      'Workspace backing retained: ${p.dirname(canonical)}',
    );
    if (!_ownsRoot()) throw retained;
    var ancestor = path;
    while (true) {
      if (FileSystemEntity.typeSync(ancestor, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw retained;
      }
      final parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
    if (root.resolveSymbolicLinksSync() != p.dirname(canonical) ||
        Directory(path).resolveSymbolicLinksSync() != path) {
      throw retained;
    }
  }

  bool _ownsRoot() {
    try {
      if (FileSystemEntity.typeSync(_marker, followLinks: false) !=
          FileSystemEntityType.file) {
        return false;
      }
      final marker = File(_marker);

      return marker.lengthSync() == _token.length &&
          marker.readAsStringSync() == _token;
    } on FileSystemException {
      return false;
    }
  }

  String _host(String path) {
    final relative = p.posix.relative(path, from: '/work');
    if (relative == '..' || relative.startsWith('../')) {
      throw const ExternalException('PermissionError', 'Outside workspace');
    }

    return p.joinAll([canonical, ...relative.split('/')]);
  }
}

Uint8List _readBoundedFile(String host, int bytesLeft) {
  final file = File(host).openSync();
  try {
    final size = file.lengthSync();
    if (size > bytesLeft) {
      throw const ExternalException('OSError', 'Workspace byte limit');
    }
    final bytes = file.readSync(size);
    if (bytes.length != size ||
        file.lengthSync() != size ||
        file.readByteSync() != -1) {
      throw const ExternalException('OSError', 'Workspace source changed');
    }

    return bytes;
  } finally {
    file.closeSync();
  }
}
