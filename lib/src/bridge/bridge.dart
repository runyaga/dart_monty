import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/session_bridge.dart';
import 'package:dart_monty/src/extension/attach_context.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

/// Dispatches one [MontySession] through registered Dart capabilities.
abstract class MontyBridge implements AttachContext {
  /// Creates a bridge that runs its code on [session].
  factory MontyBridge({
    required MontySession session,
    BridgeLogger? logger,
  }) = SessionBridge;

  /// Provides the bridge logger used to create scoped child loggers.
  BridgeLogger get logger;

  /// All registered function schemas.
  @override
  List<HostFunctionSchema> get schemas;

  /// All registered function schemas, grouped by category.
  Map<String, List<HostFunctionSchema>> get schemasByCategory;

  /// Registers a host function under an introspection category.
  void register(HostFunction function, {String? category});

  /// Unregisters a host function by name.
  void unregister(String name);

  /// Invokes a registered host function directly without Python stream
  /// wrappers.
  Future<MontyValue> invokeHostFunction(
    String name,
    Map<String, MontyValue> args, {
    void Function(BridgeEvent)? onEvent,
  });

  /// Replaces the OS handler used for calls that reach the bridge.
  @override
  void registerOs(OsHandler handler);

  /// Executes one feed and closes its stream after [BridgeRunFinished] or
  /// [BridgeRunError].
  Stream<BridgeEvent> execute(String code);

  /// Releases resources.
  void dispose();
}
