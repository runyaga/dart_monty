import 'dart:typed_data';

import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:meta/meta.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The platform interface for the Monty sandboxed Python interpreter.
///
/// Platform implementations (FFI, Web) extend this class to provide
/// concrete behavior. The app-facing `DartMonty` class delegates to
/// [instance].
///
/// See also:
/// - `dart_monty_ffi` — native FFI implementation
/// - `dart_monty_web` — web JS interop implementation
abstract class MontyPlatform extends PlatformInterface {
  /// Creates a [MontyPlatform] with the platform interface verification
  /// token.
  MontyPlatform() : super(token: _token);

  static final Object _token = Object();

  static MontyPlatform? _instance;

  /// The current platform instance.
  ///
  /// Defaults to `null` until set by a platform implementation.
  /// Throws [StateError] if accessed before being set.
  static MontyPlatform get instance {
    if (_instance == null) {
      throw StateError(
        'MontyPlatform.instance has not been set. '
        'Ensure a platform implementation is registered.',
      );
    }

    return _instance!;
  }

  /// Sets the current platform instance.
  ///
  /// The [instance] must extend [MontyPlatform] (not merely implement it)
  /// to satisfy the platform interface verification.
  static set instance(MontyPlatform instance) {
    PlatformInterface.verify(instance, _token);
    _instance = instance;
  }

  /// Resets the instance to `null`. Visible only for testing.
  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  /// Executes [code] and returns the result.
  ///
  /// Optionally pass [inputs] as a map of variable bindings, [limits]
  /// to constrain resource usage, and [scriptName] to identify the
  /// script in error messages and tracebacks.
  ///
  /// ```dart
  /// final result = await platform.run(
  ///   'x + 1',
  ///   inputs: {'x': 41},
  ///   scriptName: 'math_helper.py',
  /// );
  /// ```
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) {
    throw UnimplementedError('run() has not been implemented.');
  }

  /// Starts a multi-step execution of [code].
  ///
  /// When the code calls an external function listed in
  /// [externalFunctions], execution pauses and returns a [MontyPending]
  /// progress. Use [resume] or [resumeWithError] to continue.
  ///
  /// Pass [scriptName] to identify this script in error tracebacks
  /// and exception filename fields. Useful for multi-script pipelines
  /// where each script needs distinct error attribution.
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) {
    throw UnimplementedError('start() has not been implemented.');
  }

  /// Resumes a paused execution with the given [returnValue].
  Future<MontyProgress> resume(Object? returnValue) {
    throw UnimplementedError('resume() has not been implemented.');
  }

  /// Resumes a paused execution by raising an error with [errorMessage].
  Future<MontyProgress> resumeWithError(String errorMessage) {
    throw UnimplementedError('resumeWithError() has not been implemented.');
  }

  /// Resumes a paused execution by creating a future for the pending call.
  ///
  /// Instead of providing an immediate return value, this tells the VM
  /// that the external function call will return a future. The VM continues
  /// executing until it encounters an `await`, then yields
  /// [MontyResolveFutures].
  Future<MontyProgress> resumeAsFuture() {
    throw UnimplementedError('resumeAsFuture() has not been implemented.');
  }

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
  }) {
    throw UnimplementedError('resolveFutures() has not been implemented.');
  }

  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot() {
    throw UnimplementedError('snapshot() has not been implemented.');
  }

  /// Restores interpreter state from a binary snapshot [data].
  ///
  /// Returns a new [MontyPlatform] instance in the active state,
  /// representing a paused execution. Call [resume] or
  /// [resumeWithError] to continue execution.
  Future<MontyPlatform> restore(Uint8List data) {
    throw UnimplementedError('restore() has not been implemented.');
  }

  /// Releases resources held by this interpreter instance.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
