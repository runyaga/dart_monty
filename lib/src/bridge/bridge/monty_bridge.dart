import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_event.dart';
import 'package:dart_monty/src/bridge/bridge/bridge_middleware.dart';
import 'package:dart_monty/src/bridge/bridge/host_function.dart';
import 'package:dart_monty/src/bridge/bridge/host_function_schema.dart';

/// Bridge for LLM-generated Python calling registered Dart host functions.
///
/// Executes Python code in the Monty sandbox, dispatches external function
/// calls to registered [HostFunction] handlers, and emits [BridgeEvent]s.
abstract class MontyBridge {
  /// Logger for this bridge instance.
  ///
  /// Plugins and infrastructure code use this to create scoped child loggers
  /// via [BridgeLogger.child].
  BridgeLogger get logger;

  /// All registered function schemas.
  List<HostFunctionSchema> get schemas;

  /// Registers a host function.
  void register(HostFunction function);

  /// Unregisters a host function by name.
  void unregister(String name);

  /// Registers a [BridgeMiddleware] to intercept tool calls.
  ///
  /// First registered = outermost in the onion chain. No-op by default;
  /// override in implementations that support middleware.
  void use(BridgeMiddleware middleware) {
    // Default no-op.
  }

  /// Invokes a registered host function by name, routing through middleware.
  ///
  /// Use this to call host functions from Dart infrastructure code
  /// (e.g., orchestration loops) rather than from Python. Arguments are
  /// validated through [HostFunctionSchema.mapAndValidate] before dispatch.
  ///
  /// Throws [ArgumentError] if [name] is not registered.
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    CallRole role = const ToolCall(),
  });

  /// Executes [code] and returns a stream of lifecycle events.
  ///
  /// Events follow the bridge lifecycle:
  /// 1. [BridgeRunStarted]
  /// 2. Per external function call: Step/ToolCall events + handler execution
  /// 3. Buffered print output flushed as Text events
  /// 4. [BridgeRunFinished] or [BridgeRunError]
  Stream<BridgeEvent> execute(String code);

  /// Releases resources.
  void dispose();
}
