import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/host/context.dart' show HostContext;
import 'package:dart_monty/src/host/schema.dart' show HostFunctionSchema;
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Drives top-level runtime execution outside [HostContext] handlers.
abstract interface class MontyRuntimeRef implements HostParentRef {
  /// Starts Python execution with optional per-call inputs and OS policy.
  ExecutionHandle execute(
    String code, {
    OsHandler? os,
    Map<String, Object?>? inputs,
  });
}

/// Exposes parent events and schemas without allowing bridge re-entry.
abstract interface class HostParentRef {
  /// Attributes a child event on the parent runtime stream.
  void emitChildEvent(String childHandle, BridgeEvent event);

  /// Provides the parent runtime's registered schemas.
  List<HostFunctionSchema> get schemas;
}
