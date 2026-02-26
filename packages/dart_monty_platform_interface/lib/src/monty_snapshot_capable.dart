import 'dart:typed_data';

import 'package:dart_monty_platform_interface/src/monty_future_capable.dart';
import 'package:dart_monty_platform_interface/src/monty_platform.dart';

/// Interface for platforms that support snapshot and restore.
///
/// Platforms implement this to advertise snapshot capability. Callers
/// check `platform is MontySnapshotCapable` before invoking these methods,
/// avoiding `UnsupportedError` on platforms that lack support.
///
/// See also:
/// - [MontyPlatform] — the core platform contract
/// - [MontyFutureCapable] — companion interface for async/futures support
abstract class MontySnapshotCapable {
  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot();

  /// Restores interpreter state from a binary snapshot [data].
  ///
  /// Returns a new [MontyPlatform] instance in the active state,
  /// representing a paused execution. Call `resume` or `resumeWithError`
  /// to continue execution.
  Future<MontyPlatform> restore(Uint8List data);
}
