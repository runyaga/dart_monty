import 'package:dart_monty/src/bridge/bridge/monty_plugin.dart';
import 'package:signals_core/signals_core.dart';

/// Unifies the "plugin owns a single primary state signal" pattern.
///
/// Plugins that expose reactive state (e.g. `EventLoopPlugin`,
/// `SandboxPlugin`) historically allocated their own `Signal<T>`, exposed it
/// via a plugin-specific getter (`channelStateSignal`, `childrenSignal`), and
/// had to remember to call `.dispose()` in [MontyPlugin.onDispose]. Over four
/// plugins that ceremony produced inconsistent disposal: some signals leaked,
/// some were double-disposed.
///
/// This mixin owns one primary signal for the plugin, guarantees disposal,
/// and leaves the plugin free to add additional signals layered on top (for
/// example, a `Computed<int>` derived count, or a secondary state signal).
/// Secondary signals are still disposed manually inside [onDispose].
///
/// ```dart
/// class MyPlugin extends MontyPlugin with StatefulPlugin<MyState> {
///   MyPlugin() {
///     setInitialState(const MyState.initial());
///   }
///
///   @override
///   String get namespace => 'my';
/// }
/// ```
///
/// Subclasses MUST call [setInitialState] once before any reactive read; the
/// recommended spot is the plugin's constructor body.
mixin StatefulPlugin<T> on MontyPlugin {
  Signal<T>? _stateSignal;

  /// The reactive primary state of this plugin.
  ///
  /// Subscribe via [effect] to react to changes; read [state] for a
  /// non-reactive snapshot.
  ReadonlySignal<T> get stateSignal {
    final s = _stateSignal;
    if (s == null) {
      throw StateError(
        'StatefulPlugin<$T>.setInitialState() must be called before '
        'reading stateSignal. Call it in the plugin constructor.',
      );
    }

    return s;
  }

  /// Current non-reactive value of [stateSignal].
  T get state => stateSignal.value;

  /// Sets the initial state for [stateSignal]. Call once from the plugin's
  /// constructor body, before any handler runs.
  void setInitialState(T initial) {
    _stateSignal ??= signal<T>(initial);
  }

  /// Updates [stateSignal].
  ///
  /// Intended for subclasses to publish state transitions. External
  /// consumers observe via [stateSignal].
  set state(T next) {
    final s = _stateSignal;
    if (s == null) {
      throw StateError(
        'StatefulPlugin<$T>.setInitialState() must be called before '
        'writing state.',
      );
    }
    s.value = next;
  }

  @override
  Future<void> onDispose() async {
    await super.onDispose();
    _stateSignal?.dispose();
  }
}
