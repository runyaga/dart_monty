import 'package:dart_monty/src/bridge/os_call/os_provider.dart';
import 'package:dart_monty/src/monty_factory.dart';
import 'package:dart_monty/src/platform/monty_limits.dart';
import 'package:dart_monty/src/platform/monty_platform.dart';
import 'package:dart_monty/src/platform/monty_progress.dart';
import 'package:dart_monty/src/platform/monty_resource_usage.dart';
import 'package:dart_monty/src/platform/monty_result.dart';

/// Monty sandboxed Python interpreter.
///
/// Uses compile-time conditional imports to select the backend:
/// - Native (macOS, Linux, Windows): Rust FFI via `dart:ffi`
/// - Web (browser): WASM via `dart:js_interop`
///
/// ```dart
/// final monty = Monty();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
///
/// For one-shot evaluation without manual lifecycle management:
/// ```dart
/// final result = await Monty.exec('2 + 2');
/// ```
///
/// To enable filesystem/environment access from Python:
/// ```dart
/// final monty = Monty(os: defaultSandboxOs());
/// ```
class Monty {
  /// Creates a Monty interpreter with the auto-detected backend.
  ///
  /// Pass [os] to enable Python `pathlib`, `os`, and `datetime`
  /// access. Without a handler, OS calls resume with a `PermissionError`.
  factory Monty({OsProvider? os}) => Monty._(createPlatformMonty(), os);

  /// Creates a Monty interpreter with an explicit backend.
  ///
  /// Use this when you need a specific backend or custom configuration:
  /// ```dart
  /// final monty = Monty.withPlatform(myCustomPlatform);
  /// ```
  factory Monty.withPlatform(
    MontyPlatform platform, {
    OsProvider? os,
  }) => Monty._(platform, os);

  const Monty._(this._platform, this._os);

  final MontyPlatform _platform;
  final OsProvider? _os;

  /// Access the underlying platform for capability checks.
  ///
  /// ```dart
  /// if (monty.platform is MontySnapshotCapable) { ... }
  /// ```
  MontyPlatform get platform => _platform;

  /// Executes Python [code] and returns the result.
  ///
  /// When an [OsProvider] is configured, OS calls (pathlib, os, datetime)
  /// are dispatched through it automatically. Without a handler, OS calls
  /// resume Python with a `PermissionError`.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    if (_os == null) {
      return _platform.run(code, limits: limits, scriptName: scriptName);
    }

    // Iterative path: handle OS calls via the handler.
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

  /// Starts iterative execution of [code].
  ///
  /// Returns [MontyProgress] which may be [MontyPending], [MontyOsCall],
  /// [MontyResolveFutures], or [MontyComplete]. Use [resume] or
  /// [resumeWithError] to continue execution.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) => _platform.start(
    code,
    externalFunctions: externalFunctions,
    limits: limits,
    scriptName: scriptName,
  );

  /// Resumes a paused execution with [returnValue].
  Future<MontyProgress> resume(Object? returnValue) =>
      _platform.resume(returnValue);

  /// Resumes a paused execution by raising an error with [errorMessage].
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _platform.resumeWithError(errorMessage);

  /// Disposes the interpreter and releases all resources.
  Future<void> dispose() => _platform.dispose();

  /// One-shot Python evaluation with automatic resource cleanup.
  ///
  /// Creates a Monty instance, runs [code], disposes, and returns the result.
  /// Equivalent to:
  /// ```dart
  /// final monty = Monty(os: os);
  /// try {
  ///   return await monty.run(code, limits: limits, scriptName: scriptName);
  /// } finally {
  ///   await monty.dispose();
  /// }
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
