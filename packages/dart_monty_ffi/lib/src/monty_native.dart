import 'dart:typed_data';

import 'package:dart_monty_ffi/src/native_isolate_bindings.dart';
import 'package:dart_monty_ffi/src/native_isolate_bindings_impl.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';
import 'package:dart_monty_platform_interface/monty_backend_spi.dart';

/// Native Isolate implementation of [MontyPlatform].
///
/// Uses a [NativeIsolateBindings] abstraction to call into a background Isolate
/// that runs the native FFI. Manages a state machine: idle -> active ->
/// disposed.
///
/// ```dart
/// final monty = MontyNative();
/// await monty.initialize();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyNative extends MontyPlatform
    with MontyStateMixin
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyNative] with optional [bindings].
  ///
  /// Defaults to [NativeIsolateBindingsImpl] when omitted.
  MontyNative({NativeIsolateBindings? bindings})
    : _bindings = bindings ??
            NativeIsolateBindingsImpl(); // coverage:ignore-line

  final NativeIsolateBindings _bindings;
  bool _initialized = false;

  @override
  String get backendName => 'MontyNative';

  /// Initializes the background Isolate.
  ///
  /// Must be called before any execution methods. Initialization is
  /// idempotent — subsequent calls return immediately.
  ///
  /// Throws [StateError] if the Isolate fails to start.
  Future<void> initialize() async {
    if (_initialized) return;
    final ok = await _bindings.init();
    if (!ok) {
      throw StateError('Failed to initialize native Isolate');
    }
    _initialized = true;
  }

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    markActive();
    try {
      await _ensureInitialized();

      return await _bindings.run(
        code,
        limits: limits,
        scriptName: scriptName,
      );
    } finally {
      markIdle();
    }
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    markActive();
    try {
      await _ensureInitialized();

      final progress = await _bindings.start(
        code,
        externalFunctions: externalFunctions,
        limits: limits,
        scriptName: scriptName,
      );

      return _handleProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) {
    assertNotDisposed('resume');
    assertActive('resume');

    return _safeBindingsCall(() => _bindings.resume(returnValue));
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    return _safeBindingsCall(() => _bindings.resumeWithError(errorMessage));
  }

  @override
  Future<MontyProgress> resumeAsFuture() {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');

    return _safeBindingsCall(_bindings.resumeAsFuture);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) {
    assertNotDisposed('resolveFutures');
    assertActive('resolveFutures');

    return _safeBindingsCall(
      () => _bindings.resolveFutures(results, errors: errors),
    );
  }

  @override
  Future<Uint8List> snapshot() {
    assertNotDisposed('snapshot');
    assertActive('snapshot');

    return _bindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    assertNotDisposed('restore');
    assertIdle('restore');

    await _bindings.restore(data);

    return MontyNative(bindings: _bindings)
      .._initialized = _initialized
      ..markActive();
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;

    if (_initialized) {
      await _bindings.dispose();
    }
    markDisposed();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
  }

  /// Calls [fn] and handles progress. If [fn] throws, marks idle
  /// (execution is over) and rethrows.
  Future<MontyProgress> _safeBindingsCall(
    Future<MontyProgress> Function() fn,
  ) async {
    try {
      final progress = await fn();

      return _handleProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  MontyProgress _handleProgress(MontyProgress progress) {
    switch (progress) {
      case MontyComplete():
        markIdle();

        return progress;

      case MontyPending():
      case MontyResolveFutures():
        markActive();

        return progress;
    }
  }
}
