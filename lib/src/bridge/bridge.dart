import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Bridge for LLM-generated Python calling registered Dart host functions.
///
/// Executes Python code on a [MontySession], dispatches external function
/// calls to registered [HostFunction] handlers, and emits [BridgeEvent]s.
///
/// ```dart
/// final session = await monty.checkout();
/// final bridge = MontyBridge(session: session);
/// bridge.registerOs(OSAccess().call);
/// bridge.register(myHostFunction);
/// final events = bridge.execute('result = my_function()');
/// ```
abstract class MontyBridge implements AttachContext {
  /// Creates a bridge that runs its code on [session].
  factory MontyBridge({
    required MontySession session,
    BridgeLogger? logger,
  }) = SessionBridge;

  /// Logger for this bridge instance.
  ///
  /// Plugins and infrastructure code use this to create scoped child loggers
  /// via [BridgeLogger.child].
  BridgeLogger get logger;

  /// All registered function schemas.
  @override
  List<HostFunctionSchema> get schemas;

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
  Future<MontyValue> invokeHostFunction(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  });

  /// Registers an [OsHandler] for OS-level calls (pathlib, os, datetime),
  /// replacing the one registered before.
  ///
  /// The bridge passes the handler to each feed, wrapped to emit
  /// [BridgeOsCallStart] and [BridgeOsCallResult] for every call it
  /// receives. With no handler, the bridge passes none, and the worker
  /// answers each OS call with its default. Calls the worker answers itself
  /// (mounts, the OS policy) never reach the handler and emit no events.
  @override
  void registerOs(OsHandler handler);

  /// Executes [code] as one feed on the session and returns a stream of
  /// lifecycle events:
  /// 1. [BridgeRunStarted];
  /// 2. the call events of each host-function and OS call the host answers;
  /// 3. [BridgeRunFinished] or [BridgeRunError], carrying the print text
  ///    collected during the run as `printOutput`.
  ///
  /// A Python or worker failure ends the stream with [BridgeRunError]; the
  /// stream itself does not error. Throws [StateError] if the bridge is
  /// disposed or another execution is in progress.
  Stream<BridgeEvent> execute(String code);

  /// Releases resources.
  void dispose();
}
