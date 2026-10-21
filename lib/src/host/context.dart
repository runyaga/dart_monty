import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/host/function.dart' show HostFunctionHandler;
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Runs Python in a fresh session with optional top-level inputs.
typedef HostSubExecutor =
    Future<MontyValue> Function(String code, {Map<String, MontyValue>? inputs});

/// Provides execution-scoped capabilities to each [HostFunctionHandler].
@immutable
class HostContext {
  /// Captures the capabilities available during one host function call.
  HostContext({
    required this.emit,
    required this.executionId,
    CancelToken? cancelToken,
    this.os,
    this.parent,
    this.subExecute,
  }) : cancelToken = cancelToken ?? CancelToken();

  /// Emits an event before the current host function result.
  final void Function(BridgeEvent event) emit;

  /// Identifies the current call in execution events.
  final String executionId;

  /// Signals cooperative cancellation to handler work.
  final CancelToken cancelToken;

  /// Exposes the active OS handler without routing through Python.
  final OsHandler? os;

  /// Exposes event forwarding and schemas without bridge re-entry.
  final HostParentRef? parent;

  /// Runs isolated Python on another session while the caller's bridge runs.
  final HostSubExecutor? subExecute;

  /// Emits progress text before the current host function result.
  void emitText(String text) =>
      emit(BridgeFunctionEmit(callId: executionId, text: text));
}
