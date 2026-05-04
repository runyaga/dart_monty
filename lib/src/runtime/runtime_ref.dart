import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/host/context.dart' show HostContext;
import 'package:dart_monty/src/host/schema.dart' show HostFunctionSchema;
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Minimal interface that internal extension/plugin code uses to drive
/// the owning runtime — top-level execute, event forwarding, etc.
///
/// Defined as a separate abstract interface to break the circular dependency
/// between `host/context.dart` → this file and `monty_runtime.dart` →
/// `host/function.dart` → `host/context.dart`.
///
/// **Not safe to use from inside [HostContext] handlers.** Calling [execute]
/// from a host function deadlocks the bridge — the parent execution still
/// holds the bridge lock. Host functions get the narrower [HostParentRef]
/// (event forwarding + schema introspection only) plus `ctx.subExecute` for
/// fresh sub-runs.
abstract interface class MontyRuntimeRef implements HostParentRef {
  /// Executes Python [code] in this runtime and returns an [ExecutionHandle]
  /// carrying the events stream, terminal result future, and cancel hook.
  ///
  /// Passing [os] overrides the runtime's session OS handler for this one
  /// call. Children spawned during the execution inherit the override.
  ///
  /// [inputs] injects per-invocation Python variables before [code] runs.
  /// Each key becomes a top-level Python variable — mirrors `MontyRepl.feedRun`
  /// so the API is consistent across the stack.
  ///
  /// ```dart
  /// runtime.execute(code, inputs: {'greeting': 'hello', 'name': 'Alice'});
  /// ```
  /// ```python
  /// print(f"{greeting}, {name}!")
  /// ```
  ExecutionHandle execute(
    String code, {
    OsCallHandler? os,
    Map<String, Object?>? inputs,
  });
}

/// The narrow slice of the parent runtime exposed to host function handlers
/// via [HostContext.parent].
///
/// Deliberately omits `execute()` — calling it from a host function would
/// deadlock the bridge (the outer execution still holds the bridge lock).
/// Use `ctx.subExecute` for sub-executions; it runs in a fresh interpreter
/// via `Monty(code).run()` and therefore does not contend with the lock.
abstract interface class HostParentRef {
  /// Emits [event] on the parent runtime's broadcast `events` stream wrapped
  /// as a `BridgeChildEvent` tagged with [childHandle].
  ///
  /// Used by child-spawning extensions (e.g. `SandboxExtension`) to aggregate
  /// child execution events into the parent's event stream so observers see
  /// a single attributed ordering across the ownership tree.
  void emitChildEvent(String childHandle, BridgeEvent event);

  /// All host function schemas registered on the parent runtime.
  ///
  /// Host functions can introspect the available tool surface — e.g. the
  /// `requires()` host function uses this to verify that declared
  /// dependencies are actually wired up before a script proceeds.
  List<HostFunctionSchema> get schemas;
}
