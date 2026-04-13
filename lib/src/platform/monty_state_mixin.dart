import 'package:meta/meta.dart';
import 'package:signals_core/signals_core.dart';

/// Platform interpreter lifecycle state.
///
/// Exposed via [MontyStateMixin.stateSignal] for reactive observation.
/// Use [MontyStateMixin.isIdle], [MontyStateMixin.isActive], and
/// [MontyStateMixin.isDisposed] for non-reactive one-shot reads.
enum MontyLifecycleState {
  /// Initial state, or after each code-completion cycle.
  idle,

  /// Actively executing code.
  active,

  /// Permanently released — no further execution is possible.
  disposed,
}

/// Shared lifecycle state machine for `MontyPlatform` backends.
///
/// Provides guard methods, state transition methods, boolean getters, and a
/// reactive [stateSignal] that enforces the
/// idle → active ↔ pending → idle | disposed contract.
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
///
/// ## Reactive observation
///
/// Subscribe to [stateSignal] to react to lifecycle transitions:
///
/// ```dart
/// effect(() {
///   if (platform.stateSignal.value == MontyLifecycleState.disposed) {
///     log.info('platform released');
///   }
/// });
/// ```
mixin MontyStateMixin {
  /// Display name used in error messages (e.g. `'MontyFfi'`).
  String get backendName;

  final Signal<MontyLifecycleState> _stateSignal = signal(
    MontyLifecycleState.idle,
  );

  /// Reactive platform lifecycle state.
  ///
  /// Emits on every transition: idle → active on each `start()`, active →
  /// idle on each completion, and → disposed exactly once when `dispose()`
  /// is called.
  ///
  /// Use [isIdle], [isActive], [isDisposed] for non-reactive one-shot reads.
  ReadonlySignal<MontyLifecycleState> get stateSignal => _stateSignal;

  /// Whether the instance is idle (initial state, or after completion).
  bool get isIdle => _stateSignal.value == MontyLifecycleState.idle;

  /// Whether the instance is actively executing code.
  bool get isActive => _stateSignal.value == MontyLifecycleState.active;

  /// Whether the instance has been disposed.
  bool get isDisposed => _stateSignal.value == MontyLifecycleState.disposed;

  /// Throws [StateError] if this instance has been disposed.
  @protected
  void assertNotDisposed(String method) {
    if (_stateSignal.value == MontyLifecycleState.disposed) {
      throw StateError('Cannot call $method() on a disposed $backendName');
    }
  }

  /// Throws [StateError] if execution is currently active.
  @protected
  void assertIdle(String method) {
    if (_stateSignal.value == MontyLifecycleState.active) {
      throw StateError(
        'Cannot call $method() while execution is active. '
        'Call resume(), resumeWithError(), or dispose() first.',
      );
    }
  }

  /// Throws [StateError] if execution is not currently active.
  @protected
  void assertActive(String method) {
    if (_stateSignal.value != MontyLifecycleState.active) {
      throw StateError(
        'Cannot call $method() when not in active state. '
        'Call start() first.',
      );
    }
  }

  /// Transitions to the active state.
  @protected
  void markActive() {
    _stateSignal.value = MontyLifecycleState.active;
  }

  /// Transitions to the idle state.
  @protected
  void markIdle() {
    _stateSignal.value = MontyLifecycleState.idle;
  }

  /// Transitions to the disposed state.
  ///
  /// The signal retains its [MontyLifecycleState.disposed] value so that
  /// guard methods (e.g. [assertNotDisposed]) remain readable after disposal.
  /// The signal is released when the owning backend is garbage collected.
  @protected
  void markDisposed() {
    _stateSignal.value = MontyLifecycleState.disposed;
  }
}
