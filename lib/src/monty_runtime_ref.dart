import 'package:dart_monty/dart_monty_bridge.dart' show HostContext;
import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/execution_handle.dart';
import 'package:dart_monty/src/host_context.dart' show HostContext;
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
  /// Executes Python [code] in this runtime and returns an [ExecutionHandle]
  /// carrying the events stream, terminal result future, and cancel hook.
  ///
  /// Passing [os] overrides the runtime's session OS handler for this one
  /// call. Children spawned during the execution inherit the override.
  ExecutionHandle execute(String code, {OsCallHandler? os});

  /// Emits [event] on this runtime's broadcast `events` stream wrapped as a
  /// [BridgeChildEvent] tagged with [childHandle].
  ///
  /// Used by child-spawning plugins (e.g. `SandboxExtension`) to aggregate
  /// child execution events into the parent's event stream so observers see a
  /// single attributed ordering across the ownership tree.
  void emitChildEvent(String childHandle, BridgeEvent event);
}
