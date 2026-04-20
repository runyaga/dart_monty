import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Minimal interface that [HostContext] uses to reference the owning runtime.
///
/// Defined as a separate abstract interface to break the circular dependency
/// between `host_context.dart` → this file and `monty_runtime.dart` →
/// `host_function.dart` → `host_context.dart`.
///
/// `MontyRuntime` implements this interface; host function handlers that need
/// to spin up a sub-execution should type their `ctx.runtime` as
/// [MontyRuntimeRef].
abstract interface class MontyRuntimeRef {
  /// Executes Python [code] in this runtime and returns the result.
  Future<MontyResult> execute(String code);

  /// Emits [event] on this runtime's broadcast `events` stream wrapped as a
  /// [BridgeChildEvent] tagged with [childHandle].
  ///
  /// Used by child-spawning plugins (e.g. `SandboxPlugin`) to aggregate child
  /// execution events into the parent's event stream so observers see a single
  /// attributed ordering across the ownership tree.
  void emitChildEvent(String childHandle, BridgeEvent event);
}
