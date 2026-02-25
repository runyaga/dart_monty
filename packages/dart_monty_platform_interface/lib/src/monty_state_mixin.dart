import 'package:meta/meta.dart';

/// Library-private interpreter lifecycle state.
///
/// Backends access state only through [MontyStateMixin] getters and
/// transition methods — never through this enum directly.
enum _MontyState { idle, active, disposed }

/// Shared lifecycle state machine for `MontyPlatform` backends.
///
/// Provides guard methods, state transition methods, and boolean getters
/// that enforce the idle -> active <-> pending -> idle | disposed contract.
///
/// Backends mix this in and override [backendName] to customize error
/// messages:
///
/// ```dart
/// class MyBackend extends MontyPlatform with MontyStateMixin {
///   @override
///   String get backendName => 'MyBackend';
/// }
/// ```
mixin MontyStateMixin {
  /// Display name used in error messages (e.g. `'MontyFfi'`).
  String get backendName;

  _MontyState _state = _MontyState.idle;

  /// Whether the instance is idle (initial state, or after completion).
  bool get isIdle => _state == _MontyState.idle;

  /// Whether the instance is actively executing code.
  bool get isActive => _state == _MontyState.active;

  /// Whether the instance has been disposed.
  bool get isDisposed => _state == _MontyState.disposed;

  /// Throws [StateError] if this instance has been disposed.
  @protected
  void assertNotDisposed(String method) {
    if (_state == _MontyState.disposed) {
      throw StateError('Cannot call $method() on a disposed $backendName');
    }
  }

  /// Throws [StateError] if execution is currently active.
  @protected
  void assertIdle(String method) {
    if (_state == _MontyState.active) {
      throw StateError(
        'Cannot call $method() while execution is active. '
        'Call resume(), resumeWithError(), or dispose() first.',
      );
    }
  }

  /// Throws [StateError] if execution is not currently active.
  @protected
  void assertActive(String method) {
    if (_state != _MontyState.active) {
      throw StateError(
        'Cannot call $method() when not in active state. '
        'Call start() first.',
      );
    }
  }

  /// Transitions to the active state.
  @protected
  void markActive() {
    _state = _MontyState.active;
  }

  /// Transitions to the idle state.
  @protected
  void markIdle() {
    _state = _MontyState.idle;
  }

  /// Transitions to the disposed state.
  @protected
  void markDisposed() {
    _state = _MontyState.disposed;
  }

  /// Throws [UnsupportedError] if [inputs] is non-null and non-empty.
  @protected
  void rejectInputs(Map<String, Object?>? inputs) {
    if (inputs != null && inputs.isNotEmpty) {
      throw UnsupportedError(
        'The $backendName backend does not support the inputs parameter. '
        'Use externalFunctions with start()/resume() instead.',
      );
    }
  }
}
