import 'dart:typed_data';

import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
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
  static void resetInstance() {
    _instance = null;
  }

  /// Executes [code] and returns the result.
  ///
  /// Optionally pass [inputs] as a map of variable bindings and [limits]
  /// to constrain resource usage.
  Future<MontyResult> run(
    String code, {
    Map<String, Object?>? inputs,
    MontyLimits? limits,
  }) {
    throw UnimplementedError('run() has not been implemented.');
  }

  /// Starts a multi-step execution of [code].
  ///
  /// When the code calls an external function listed in
  /// [externalFunctions], execution pauses and returns a [MontyPending]
  /// progress. Use [resume] or [resumeWithError] to continue.
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
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

  /// Captures the current interpreter state as a binary snapshot.
  Future<Uint8List> snapshot() {
    throw UnimplementedError('snapshot() has not been implemented.');
  }

  /// Restores interpreter state from a binary snapshot [data].
  ///
  /// Returns a new [MontyPlatform] instance representing the restored
  /// session.
  Future<MontyPlatform> restore(Uint8List data) {
    throw UnimplementedError('restore() has not been implemented.');
  }

  /// Releases resources held by this interpreter instance.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
