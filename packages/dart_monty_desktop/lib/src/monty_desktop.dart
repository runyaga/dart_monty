import 'dart:typed_data';

import 'package:dart_monty_desktop/src/desktop_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Desktop Isolate implementation of [MontyPlatform].
///
/// Uses a [DesktopBindings] abstraction to call into a background Isolate
/// that runs the native FFI. Manages a state machine: idle -> active ->
/// disposed.
///
/// ```dart
/// final monty = MontyDesktop(bindings: DesktopBindingsIsolate());
/// await monty.initialize();
/// final result = await monty.run('2 + 2');
/// print(result.value); // 4
/// await monty.dispose();
/// ```
class MontyDesktop extends MontyPlatform with MontyStateMixin {
  /// Creates a [MontyDesktop] with the given [bindings].
  MontyDesktop({required DesktopBindings bindings}) : _bindings = bindings;

  @override
  String get backendName => 'MontyDesktop';

  final DesktopBindings _bindings;
  bool _initialized = false;

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
      throw StateError('Failed to initialize desktop Isolate');
    }
    _initialized = true;
  }

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await initialize();
    }
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

    final result = await _bindings.run(
      code,
      limits: limits,
      scriptName: scriptName,
    );
    return result;
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

    final progress = await _bindings.resume(returnValue);
    return _handleProgress(progress);
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');

    final progress = await _bindings.resumeWithError(errorMessage);
    return _handleProgress(progress);
  }

  @override
  Future<MontyProgress> resumeAsFuture() async {
    assertNotDisposed('resumeAsFuture');
    assertActive('resumeAsFuture');

    final progress = await _bindings.resumeAsFuture();
    return _handleProgress(progress);
  }

  @override
  Future<MontyProgress> resolveFutures(
    Map<int, Object?> results, {
    Map<int, String>? errors,
  }) async {
    assertNotDisposed('resolveFutures');
    assertActive('resolveFutures');

    final progress = await _bindings.resolveFutures(results, errors: errors);
    return _handleProgress(progress);
  }

  @override
  Future<Uint8List> snapshot() async {
    assertNotDisposed('snapshot');
    assertActive('snapshot');

    return _bindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    assertNotDisposed('restore');
    assertIdle('restore');

    await _bindings.restore(data);
    final restored = MontyDesktop(bindings: _bindings)
      .._initialized = _initialized
      ..markActive();
    return restored;
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
  // Progress handling
  // ---------------------------------------------------------------------------

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
