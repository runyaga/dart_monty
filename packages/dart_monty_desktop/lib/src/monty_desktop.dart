import 'dart:typed_data';

import 'package:dart_monty_desktop/src/desktop_bindings.dart';
import 'package:dart_monty_platform_interface/dart_monty_platform_interface.dart';

/// Interpreter lifecycle state.
enum _State { idle, active, disposed }

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
class MontyDesktop extends MontyPlatform {
  /// Creates a [MontyDesktop] with the given [bindings].
  MontyDesktop({required DesktopBindings bindings}) : _bindings = bindings;

  final DesktopBindings _bindings;
  _State _state = _State.idle;
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
  }) async {
    _assertNotDisposed('run');
    _assertIdle('run');
    _rejectInputs(inputs);
    await _ensureInitialized();

    final result = await _bindings.run(code, limits: limits);
    return result.result;
  }

  @override
  Future<MontyProgress> start(
    String code, {
    Map<String, Object?>? inputs,
    List<String>? externalFunctions,
    MontyLimits? limits,
  }) async {
    _assertNotDisposed('start');
    _assertIdle('start');
    _rejectInputs(inputs);
    await _ensureInitialized();

    final progress = await _bindings.start(
      code,
      externalFunctions: externalFunctions,
      limits: limits,
    );
    return _handleProgress(progress.progress);
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    _assertNotDisposed('resume');
    _assertActive('resume');

    final progress = await _bindings.resume(returnValue);
    return _handleProgress(progress.progress);
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    _assertNotDisposed('resumeWithError');
    _assertActive('resumeWithError');

    final progress = await _bindings.resumeWithError(errorMessage);
    return _handleProgress(progress.progress);
  }

  @override
  Future<Uint8List> snapshot() async {
    _assertNotDisposed('snapshot');
    _assertActive('snapshot');

    return _bindings.snapshot();
  }

  @override
  Future<MontyPlatform> restore(Uint8List data) async {
    _assertNotDisposed('restore');
    _assertIdle('restore');

    await _bindings.restore(data);
    final restored = MontyDesktop(bindings: _bindings)
      .._initialized = _initialized;
    return restored;
  }

  @override
  Future<void> dispose() async {
    if (_state == _State.disposed) return;

    if (_initialized) {
      await _bindings.dispose();
    }
    _state = _State.disposed;
  }

  // ---------------------------------------------------------------------------
  // Progress handling
  // ---------------------------------------------------------------------------

  MontyProgress _handleProgress(MontyProgress progress) {
    switch (progress) {
      case MontyComplete():
        _state = _State.idle;
        return progress;

      case MontyPending():
        _state = _State.active;
        return progress;
    }
  }

  // ---------------------------------------------------------------------------
  // State assertions
  // ---------------------------------------------------------------------------

  void _assertNotDisposed(String method) {
    if (_state == _State.disposed) {
      throw StateError('Cannot call $method() on a disposed MontyDesktop');
    }
  }

  void _assertIdle(String method) {
    if (_state == _State.active) {
      throw StateError(
        'Cannot call $method() while execution is active. '
        'Call resume(), resumeWithError(), or dispose() first.',
      );
    }
  }

  void _assertActive(String method) {
    if (_state != _State.active) {
      throw StateError(
        'Cannot call $method() when not in active state. '
        'Call start() first.',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _rejectInputs(Map<String, Object?>? inputs) {
    if (inputs != null && inputs.isNotEmpty) {
      throw UnsupportedError(
        'The desktop backend does not support the inputs parameter. '
        'Use externalFunctions with start()/resume() instead.',
      );
    }
  }
}
