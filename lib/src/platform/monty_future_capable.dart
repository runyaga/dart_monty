import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_snapshot_capable.dart';

/// Interface for platforms that support async/futures execution.
///
/// Platforms implement this to advertise futures capability. Callers
/// check `platform is MontyFutureCapable` before invoking these methods,
/// avoiding `UnsupportedError` on platforms where the upstream runtime
/// does not expose the futures state machine.
///
/// See also:
/// - [MontyPlatform] — the core platform contract
/// - [MontySnapshotCapable] — companion interface for snapshot/restore
abstract class MontyFutureCapable extends MontyPlatform {
  /// Resumes a paused execution by creating a future for the pending call.
  ///
  /// Instead of providing an immediate return value, this tells the VM
  /// that the external function call will return a future. The VM continues
  /// executing until it encounters an `await`, then yields
  /// [MontyResolveFutures].
  Future<MontyProgress> resumeAsFuture();

  /// Resolves pending futures with their results, and optionally errors.
  ///
  /// [results] maps call IDs to their resolved values. All pending call IDs
  /// from [MontyResolveFutures.pendingCallIds] should be present in either
  /// [results] or [errors].
  ///
  /// [errors] optionally maps call IDs to error message strings (raises
  /// RuntimeError in Python for each).
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  });
}
