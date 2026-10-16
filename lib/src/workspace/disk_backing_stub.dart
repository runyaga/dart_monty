import 'dart:typed_data';

import 'package:dart_monty/src/workspace/disk_backing.dart';

/// Creates owned backing, or refuses when native mounts are unavailable.
DiskBacking createDiskBacking(String _, Map<String, Uint8List?> _) =>
    throw UnsupportedError('Native workspace backing is unavailable on web');
