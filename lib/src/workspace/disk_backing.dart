import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

/// Internal capability: implementations create and own their backing.
abstract interface class DiskBacking {
  /// Starts a bounded pool used only for persistent transfers.
  Future<Monty> startTransferPool();

  /// Opens a short-lived native capability.
  MountDir open({String mode = 'read-write'});

  /// Refuses links and paths outside the owned root.
  void validate(String path);

  /// Whether two existing workspace paths resolve to the same host entry.
  bool sameHostEntry(String path, String other);

  /// Reads a stable bounded namespace without following links.
  Future<Map<String, Uint8List?>> snapshot({
    required int maxBytes,
    Iterable<String> roots = const ['/work'],
    int maxEntries = 4096,
    int maxDepth = 32,
  });

  /// Deletes only the owned directory.
  void dispose();
}
