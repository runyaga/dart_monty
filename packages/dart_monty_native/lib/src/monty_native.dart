import 'dart:typed_data';

import 'package:dart_monty_native/src/native_isolate_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Native Isolate implementation of [MontyPlatform].
///
/// Uses a [NativeIsolateBindings] abstraction to call into a background Isolate
/// that runs the native FFI. Manages a state machine: idle -> active ->
/// disposed.
///
/// ```dart
/// final monty = MontyNative(bindings: NativeIsolateBindingsImpl());
/// await monty.initialize();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyNative extends MontyPlatform
    with MontyStateMixin
    implements MontySnapshotCapable, MontyFutureCapable {
  /// Creates a [MontyNative] with the given [bindings].
  MontyNative({required NativeIsolateBindings bindings}) : _bindings = bindings;

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
    Map<String, Object?>? inputs,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    rejectInputs(inputs);
    await _ensureInitialized();

    return _bindings.run(
      code,
      limits: limits,
      scriptName: scriptName,
    );
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    rejectInputs(inputs);
    await _ensureInitialized();

    final progress = await _bindings.start(
      code,
      externalFunctions: externalFunctions,
      limits: limits,
      scriptName: scriptName,
    );

    return _handleProgress(progress);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');

    return _safeBindingsCall(() => _bindings.resume(returnValue));
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    return _safeBindingsCall(() => _bindings.resumeWithError(errorMessage));
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');

    return _safeBindingsCall(_bindings.resumeAsFuture);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
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
    } on MontyException {
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
