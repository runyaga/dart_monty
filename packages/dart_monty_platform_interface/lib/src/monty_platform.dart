import 'package:dart_monty_platform_interface/src/monty_limits.dart';
import 'package:dart_monty_platform_interface/src/monty_progress.dart';
import 'package:dart_monty_platform_interface/src/monty_result.dart';
import 'package:meta/meta.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The platform interface for the Monty sandboxed Python interpreter.
///
/// Platform implementations (FFI, Web) extend this class to provide
/// concrete behavior.
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
  ///
  /// Deprecated: Instantiate platform implementations directly instead
  /// of relying on a global singleton. Pass the platform explicitly to
  /// consumers (e.g. `DefaultMontyBridge(platform: myPlatform)`).
  @Deprecated(
    'Instantiate MontyFfi/MontyWasm/MontyNative directly instead of '
    'using the global singleton. Will be removed in 1.0.',
  )
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
  ///
  /// Deprecated: See getter deprecation. Will be removed in 1.0.
  @Deprecated(
    'Instantiate MontyFfi/MontyWasm/MontyNative directly instead of '
    'using the global singleton. Will be removed in 1.0.',
  )
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
  /// Optionally pass [limits] to constrain resource usage, and
  /// [scriptName] to identify the script in error messages and tracebacks.
  ///
  /// ```dart
  /// final result = await platform.run(
  ///   'x + 1',
  ///   scriptName: 'math_helper.py',
  /// );
  /// ```
  Future<MontyResult> run(
    String code, {
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

  /// Cancels the current execution. Idempotent — safe to call multiple times.
  ///
  /// No-op after [dispose].
  Future<void> cancel() {
    throw UnimplementedError('cancel() has not been implemented.');
  }

  /// The monotonic handle ID for cross-isolate cancel.
  ///
  /// Returns `null` before the first [run]/[start] or after [dispose].
  int? get handleId => null;

  /// Releases resources held by this interpreter instance.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
