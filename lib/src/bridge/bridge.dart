import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/platform.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/function_surface.dart' show FunctionSurface;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Bridge for LLM-generated Python calling registered Dart host functions.
///
/// Executes Python code in the Monty sandbox, dispatches external function
/// calls to registered [HostFunction] handlers, and emits [BridgeEvent]s.
///
/// ```dart
/// final bridge = MontyBridge(platform: createPlatformMonty());
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
  }) = PlatformBridge;

  /// Logger for this bridge instance.
  ///
  /// Plugins and infrastructure code use this to create scoped child loggers
  /// via [BridgeLogger.child].
  BridgeLogger get logger;

  /// All registered function schemas.
  @override
  List<HostFunctionSchema> get schemas;

  /// Schemas for functions that declare [FunctionSurface.llm].
  List<HostFunctionSchema> get exposedSchemas;

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
  /// When [onEvent] is provided, any [BridgeEvent] the handler emits via
  /// `HostContext.emit` / `HostContext.emitText` is delivered to the callback
  /// before the returned future completes. When omitted, emissions are
  /// dropped. Extension-registered stream wrappers apply to [execute] only
  /// and are NOT run for direct-Dart invocations — direct calls are outside
  /// Python-execution semantics.
  ///
  /// Callback exceptions are logged and swallowed; they never fail the call.
  ///
  /// Throws [ArgumentError] if [name] is not registered.
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    void Function(BridgeEvent)? onEvent,
  });

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
