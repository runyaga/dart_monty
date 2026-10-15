import 'package:dart_monty/src/bridge/bridge.dart';
import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/bridge/struct_log_logger.dart';
import 'package:dart_monty/src/host/dispatch.dart';
import 'package:dart_monty/src/host/function.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';
import 'package:struct_log/struct_log.dart';

/// The [MontyBridge] implementation: runs its code on a [MontySession].
///
/// Registration, the OS handler and direct invocation work; running code
/// ([execute]) is not built yet (D1-2).
@internal
class SessionBridge implements MontyBridge {
  /// Creates a bridge over [session].
  SessionBridge({
    required this.session,
    BridgeLogger? logger,
    MontyRuntimeRef? runtime,
  }) : logger = logger ?? StructLogBridgeLogger.root(LogManager.instance),
       _host = HostDispatch(
         log: logger ?? StructLogBridgeLogger.root(LogManager.instance),
         runtime: runtime,
       );

  /// The session this bridge runs code on.
  final MontySession session;

  @override
  final BridgeLogger logger;

  final HostDispatch _host;

  OsHandler? _currentOsHandler;

  bool _isDisposed = false;

  // Stream wrappers registered by extensions that override
  // wrapExecuteStream. Applied in registration order (first = outermost).
  final List<Stream<BridgeEvent> Function(String, Stream<BridgeEvent>)>
  _streamWrappers = [];

  /// Registers a stream wrapper callback from an extension.
  @internal
  void addStreamWrapper(
    Stream<BridgeEvent> Function(String code, Stream<BridgeEvent> stream)
    wrapper,
  ) {
    _streamWrappers.add(wrapper);
  }

  @override
  List<HostFunctionSchema> get schemas => _host.schemas;

  @override
  Map<String, List<HostFunctionSchema>> get schemasByCategory =>
      _host.schemasByCategory;

  @override
  void register(HostFunction function, {String? category}) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _host.register(function, category: category);
  }

  @override
  void unregister(String name) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _host.unregister(name);
  }

  @override
  void registerOs(OsHandler handler) {
    if (_isDisposed) throw StateError('Bridge has been disposed');
    _currentOsHandler = handler;
    _host.osHandler = handler;
  }

  /// Replaces the currently-registered OS handler with [handler] (or clears
  /// it when `null`).
  @internal
  void setOsHandler(OsHandler? handler) {
    if (_isDisposed) return;
    _currentOsHandler = handler;
    _host.osHandler = handler;
  }

  /// The currently-registered OS handler, if any.
  @internal
  OsHandler? get currentOsHandler => _currentOsHandler;

  @override
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    void Function(BridgeEvent)? onEvent,
  }) {
    if (_isDisposed) throw StateError('Bridge has been disposed');

    return _host.invokeHostFunction(name, args, onEvent: onEvent);
  }

  @override
  Stream<BridgeEvent> execute(String code) {
    if (_isDisposed) throw StateError('Bridge has been disposed');

    throw UnimplementedError('D1-2');
  }

  @override
  void dispose() {
    _isDisposed = true;
    _currentOsHandler = null;
    _host.osHandler = null;
    logger.close();
  }
}
