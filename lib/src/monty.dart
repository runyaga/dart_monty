import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/monty_factory.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';

/// Monty sandboxed Python interpreter.
///
/// ```dart
/// final result = await Monty.exec('2 + 2');
/// print(result.value); // MontyInt(4)
/// ```
///
/// For multiple runs on the same interpreter:
/// ```dart
/// final monty = Monty();
/// final r1 = await monty.run('2 + 2');
/// final r2 = await monty.run('"hello".upper()');
/// await monty.dispose();
/// ```
///
/// To enable filesystem/environment/datetime access:
/// ```dart
/// final monty = Monty(os: OsProvider());
/// ```
class Monty {
  /// Creates a Monty interpreter with the auto-detected backend.
  ///
  /// Pass [os] to enable Python `pathlib`, `os`, and `datetime`
  /// access. Without it, OS calls resume with `PermissionError`.
  factory Monty({OsProvider? os}) => Monty._(createPlatformMonty(), os);

  /// Creates a Monty interpreter with an explicit platform backend.
  factory Monty.withPlatform(
    MontyPlatform platform, {
    OsProvider? os,
  }) => Monty._(platform, os);

  const Monty._(this._platform, this._os);

  final MontyPlatform _platform;
  final OsProvider? _os;

  /// The underlying platform — for advanced use (capability checks, etc.).
  MontyPlatform get platform => _platform;

  /// Executes Python [code] and returns the result.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    if (_os == null) {
      return _platform.run(code, limits: limits, scriptName: scriptName);
    }

    var progress = await _platform.start(
      code,
      limits: limits,
      scriptName: scriptName,
    );

    while (progress is! MontyComplete) {
      if (progress is MontyOsCall) {
        try {
          final result = await _os.resolve(progress);
          progress = await _platform.resume(result);
        } on Object catch (e) {
          progress = await _platform.resumeWithError(e.toString());
        }
      } else if (progress is MontyPending) {
        progress = await _platform.resumeWithError(
          'Unexpected external function: ${progress.functionName}',
        );
      } else if (progress is MontyResolveFutures) {
        progress = await _platform.resume(null);
      } else {
        break;
      }
    }

    if (progress is MontyComplete) {
      return progress.result;
    }

    return const MontyResult(
      usage: MontyResourceUsage(
        memoryBytesUsed: 0,
        timeElapsedMs: 0,
        stackDepthUsed: 0,
      ),
    );
  }

  /// Releases all resources.
  Future<void> dispose() => _platform.dispose();

  /// One-shot evaluation — creates, runs, disposes automatically.
  ///
  /// ```dart
  /// final result = await Monty.exec('2 + 2');
  /// ```
  static Future<MontyResult> exec(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    OsProvider? os,
  }) async {
    final monty = Monty(os: os);
    try {
      return await monty.run(code, limits: limits, scriptName: scriptName);
    } finally {
      await monty.dispose();
    }
  }
}
