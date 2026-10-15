import 'dart:async';

import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/extension/coordinator.dart';
import 'package:dart_monty/src/extension/extension.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/os_call/os_handlers.dart';
import 'package:dart_monty/src/runtime/execution_handle.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';

// ---------------------------------------------------------------------------
// MontyRuntime
// ---------------------------------------------------------------------------

/// High-level agent session — stateful Python execution with tools and
/// extensions.
///
/// Combines `MontyBridge`, `ExtensionCoordinator`, and OS providers into a
/// single API, on sessions checked out of a [Monty] pool.
///
/// Two execution modes:
///
/// **Shared interpreter** (default): one session across all `execute()`
/// calls. Variables, functions, classes, and modules defined in one call are
/// available in every subsequent call.
///
/// **Fresh sandbox** (`sandbox: true`): each `execute()` runs on its own
/// session, closed after it. State does not persist between calls.
///
/// ```dart
/// final runtime = await MontyRuntime.start(os: defaultOsHandler());
/// await runtime.execute('x = 42').result;
/// final value = await runtime.execute('x + 1').result; // MontyInt(43)
/// ```
class MontyRuntime implements MontyRuntimeRef {
  MontyRuntime._({
    OsHandler? os,
    List<MontyExtension>? extensions,
    bool sandbox = false,
  }) : _os = os,
       _extensions = extensions,
       _sandbox = sandbox {
    if (!sandbox) {
      _sharedRegistry = ExtensionCoordinator();
      if (extensions != null) {
        extensions.forEach(_sharedRegistry!.register);
      }
    }
  }

  /// How long a checkout from the runtime's default pool waits for a free
  /// worker before it fails.
  static const Duration defaultCheckoutTimeout = Duration(seconds: 30);

  // Read by execute() and clearState(), which D1-4 builds.
  // ignore: unused_field, kept for D1-4 rather than dropped and re-added.
  final OsHandler? _os;
  // ignore: unused_field, kept for D1-4 rather than dropped and re-added.
  final List<MontyExtension>? _extensions;
  final bool _sandbox;

  ExtensionCoordinator? _sharedRegistry;

  bool _disposed = false;
  final List<HostFunction> _extraFunctions = [];
  final StreamController<BridgeEvent> _eventsController =
      StreamController<BridgeEvent>.broadcast();

  /// Starts an agent session.
  ///
  /// When [sandbox] is true, each `execute()` call runs on a fresh session;
  /// state does not persist between calls. When [sandbox] is false (default),
  /// one session is reused across all calls.
  ///
  /// The sessions come from a [Monty] pool, which D1-4 adds.
  // ignore: avoid-unnecessary-futures, start checks out a session from D1-4.
  static Future<MontyRuntime> start({
    OsHandler? os,
    Map<String, OsHandler>? osHandlers,
    List<MontyExtension>? extensions,
    // ignore: avoid-unused-parameters, the bridges D1-4 builds log here.
    BridgeLogger? logger,
    bool sandbox = false,
  }) async {
    assert(
      os == null || osHandlers == null,
      'Pass either os or osHandlers, not both.',
    );

    return MontyRuntime._(
      os: os ?? (osHandlers != null ? composeOsHandlers(osHandlers) : null),
      extensions: extensions,
      sandbox: sandbox,
    );
  }

  /// All registered tool schemas — feed these to an LLM as tool definitions.
  @override
  List<HostFunctionSchema> get schemas => throw UnimplementedError('D1-4');

  /// Broadcast stream of all [BridgeEvent]s emitted across every execution,
  /// including child executions spawned via extensions such as
  /// `SandboxExtension`.
  ///
  /// Child-plugin events arrive wrapped in [BridgeChildEvent] with
  /// `childHandle` set to the plugin's local handle (e.g. a sandbox child
  /// id).
  Stream<BridgeEvent> get events => _eventsController.stream;

  @override
  void emitChildEvent(String childHandle, BridgeEvent event) {
    if (_disposed) return;
    if (_eventsController.isClosed) return;
    _eventsController.add(
      BridgeChildEvent(childHandle: childHandle, inner: event),
    );
  }

  /// Whether this session creates a fresh interpreter per `execute()`.
  bool get isSandboxMode => _sandbox;

  /// The shared [ExtensionCoordinator] for this runtime.
  ///
  /// Non-null in shared mode (the default). Always `null` in sandbox mode —
  /// each `execute()` call owns its own transient coordinator.
  ExtensionCoordinator? get coordinator => _sharedRegistry;

  /// Registers an additional host function.
  ///
  /// In sandbox mode, the function is registered on every fresh bridge.
  void register(HostFunction function) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    _extraFunctions.add(function);
  }

  /// Executes Python [code] with state persistence and full tool access.
  ///
  /// Returns an [ExecutionHandle] with the events stream, terminal result
  /// future, and a cancel hook. Passing [os] overrides the runtime's OS
  /// handler for this one call; [inputs] are bound as Python globals first.
  @override
  ExecutionHandle execute(
    String code, {
    OsHandler? os,
    Map<String, Object?>? inputs,
  }) {
    if (_disposed) throw StateError('MontyRuntime has been disposed');

    throw UnimplementedError('D1-4');
  }

  /// Invokes a registered host function directly from Dart — useful for
  /// exercising tools without routing through Python.
  ///
  /// Throws:
  /// - [StateError] if the runtime is disposed.
  /// - [UnsupportedError] if called on a sandbox-mode runtime.
  /// - [ArgumentError] if [name] is not registered.
  // ignore: avoid-unnecessary-futures, D1-4 awaits the attach here.
  Future<Object?> invoke(
    String name,
    // ignore: avoid-unused-parameters, D1-4 passes it to the bridge.
    Map<String, Object?> args, {
    // ignore: avoid-unused-parameters, D1-4 passes it to the bridge.
    void Function(BridgeEvent)? onEvent,
    // ignore: avoid-redundant-async, keeps the throws asynchronous.
  }) async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (_sandbox) {
      throw UnsupportedError(
        'MontyRuntime.invoke() is only available in shared mode. '
        'In sandbox mode, call host functions from Python via execute().',
      );
    }

    throw UnimplementedError('D1-4');
  }

  /// Clears all persisted Python state: closes the shared session and
  /// checks out a new one. A no-op in sandbox mode.
  // ignore: avoid-unnecessary-futures, D1-4 closes and re-checks out here.
  Future<void> clearState() async {
    if (_disposed) throw StateError('MontyRuntime has been disposed');
    if (_sandbox) return;

    throw UnimplementedError('D1-4');
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_sharedRegistry != null) await _sharedRegistry!.disposeAll();
    await _eventsController.close();
  }
}
