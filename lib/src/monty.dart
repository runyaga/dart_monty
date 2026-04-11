import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/monty_factory.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_result.dart';
import 'package:dart_monty/src/platform/monty_session.dart';

/// Monty sandboxed Python interpreter.
///
/// Variables persist across `run()` calls:
/// ```dart
/// final monty = Monty();
/// await monty.run('x = 42');
/// await monty.run('y = x * 2');
/// final result = await monty.run('x + y');
/// print(result.value); // 126
/// await monty.dispose();
/// ```
///
/// For one-shot evaluation:
/// ```dart
/// final result = await Monty.exec('2 + 2');
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

  Monty._(MontyPlatform platform, OsProvider? os)
    : _platform = platform,
      _session = MontySession(platform: platform, os: os);

  final MontyPlatform _platform;
  final MontySession _session;

  /// The underlying platform — for advanced use (capability checks,
  /// iterative start/resume, etc.).
  MontyPlatform get platform => _platform;

  /// The current persisted state as a JSON-decoded map.
  Map<String, Object?> get state => _session.state;

  /// Executes Python [code] and returns the result.
  ///
  /// Variables defined in [code] persist for subsequent `run()` calls.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) => _session.run(code, limits: limits, scriptName: scriptName);

  /// Clears all persisted state.
  ///
  /// After calling this, the next `run()` starts with empty globals.
  void clearState() => _session.clearState();

  /// Releases all resources.
  Future<void> dispose() async {
    _session.dispose();
    await _platform.dispose();
  }

  /// One-shot evaluation — creates, runs, disposes automatically.
  ///
  /// Stateless — no variable persistence across calls.
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
