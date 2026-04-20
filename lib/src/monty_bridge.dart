import 'package:dart_monty/dart_monty_bridge.dart' show FunctionSurface;
import 'package:dart_monty/src/attach_context.dart';
import 'package:dart_monty/src/bridge_event.dart';
import 'package:dart_monty/src/bridge_logger.dart';
import 'package:dart_monty/src/default_monty_bridge.dart';
import 'package:dart_monty/src/function_surface.dart' show FunctionSurface;
import 'package:dart_monty/src/host_dispatch.dart';
import 'package:dart_monty/src/host_function.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Bridge for LLM-generated Python calling registered Dart host functions.
///
/// Executes Python code in the Monty sandbox, dispatches external function
/// calls to registered [HostFunction] handlers, and emits [BridgeEvent]s.
///
/// ```dart
/// final bridge = MontyBridge(platform: MontyFfi());
/// bridge.registerOs(defaultSandboxOsHandler());
/// bridge.register(myHostFunction);
/// final events = bridge.execute('result = my_function()');
/// ```
abstract class MontyBridge implements AttachContext {
  /// Creates a bridge backed by [platform].
  factory MontyBridge({
    required MontyPlatform platform,
    MontyLimits? limits,
    bool useFutures,
    BridgeLogger? logger,
    MontyInterceptor? interceptor,
  }) = DefaultMontyBridge;

  /// Logger for this bridge instance.
  ///
  /// Plugins and infrastructure code use this to create scoped child loggers
  /// via [BridgeLogger.child].
  BridgeLogger get logger;

  /// All registered function schemas.
  @override
  List<HostFunctionSchema> get schemas;

  /// Schemas for functions visible to the LLM (where `surfaces` includes
  /// [FunctionSurface.llm]).
  List<HostFunctionSchema> get llmSchemas;

  /// All registered function schemas, grouped by category.
  Map<String, List<HostFunctionSchema>> get schemasByCategory;

  /// Registers a host function.
  ///
  /// When [category] is provided, the function is indexed under that category
  /// for introspection. Functions with no category go into `'uncategorized'`.
  void register(HostFunction function, {String? category});

  /// Unregisters a host function by name.
  void unregister(String name);

  /// Invokes a registered host function by [name] directly from Dart.
  ///
  /// Infra functions (where [HostFunction.isInfra] is `true`) bypass the
  /// interceptor. All others go through it.
  ///
  /// Throws [ArgumentError] if [name] is not registered.
  Future<Object?> invokeHostFunction(String name, Map<String, Object?> args);

  /// Registers an [OsCallHandler] for OS-level calls (pathlib, os, datetime).
  ///
  /// When Python code triggers an OS call and a handler is registered, the
  /// bridge invokes it and resumes Python with the result. When no handler
  /// is registered, the bridge resumes with a `PermissionError`.
  @override
  void registerOs(OsCallHandler handler);

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
