import 'package:dart_monty/src/bridge/event.dart';
import 'package:dart_monty/src/bridge/logger.dart';
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function.dart' show HostFunction;
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/runtime_ref.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// Default [HostSubExecutor] wired into every [HostContext]: a sub-execution
/// on a second session, built in D1-6.
Future<MontyValue> _defaultSubExecute(
  String code, {
  Map<String, Object?>? inputs,
}) => throw UnimplementedError('D1-6');

// ---------------------------------------------------------------------------
// HostDispatch — function registry + tool dispatch.
// ---------------------------------------------------------------------------

/// Manages host function registration and tool call dispatch for a
/// `MontyBridge`.
///
/// This is an internal implementation-detail class — it is not part of the
/// public `MontyBridge` API. Callers access it through the bridge's delegation
/// methods.
@internal
class HostDispatch {
  /// Creates a [HostDispatch].
  ///
  /// [log] is used for warning/error messages emitted during dispatch.
  HostDispatch({
    required BridgeLogger log,
    MontyRuntimeRef? runtime,
  }) : _log = log,
       _runtime = runtime;

  /// Current OS call handler — mirrored from the owning bridge so handlers
  /// receive it via [HostContext.os]. Updated by the bridge's `registerOs`.
  OsHandler? osHandler;

  final BridgeLogger _log;
  final MontyRuntimeRef? _runtime;

  final Map<String, HostFunction> _functions = {};
  final Map<String, Set<String>> _categoryIndex = {};

  int _idCounter = 0;

  // ---------------------------------------------------------------------------
  // ID generation.
  // ---------------------------------------------------------------------------

  /// Returns a unique string ID, incrementing an internal counter.
  String get nextId => '${_idCounter++}';

  // ---------------------------------------------------------------------------
  // Function registration.
  // ---------------------------------------------------------------------------

  /// All registered function schemas.
  List<HostFunctionSchema> get schemas =>
      _functions.values.map((f) => f.schema).toList(growable: false);

  /// All registered function schemas, grouped by category.
  Map<String, List<HostFunctionSchema>> get schemasByCategory {
    final result = <String, List<HostFunctionSchema>>{};
    for (final entry in _categoryIndex.entries) {
      final categorySchemas = <HostFunctionSchema>[];
      for (final name in entry.value) {
        final fn = _functions[name];
        if (fn != null) categorySchemas.add(fn.schema);
      }
      if (categorySchemas.isNotEmpty) result[entry.key] = categorySchemas;
    }

    return result;
  }

  /// Registers [function] under an optional [category].
  ///
  /// Silently skips functions whose [HostFunction.handler] is `null` on the
  /// current backend — no `supportedBackends` declaration required.
  void register(HostFunction function, {String? category}) {
    if (function.handler == null) return;
    final name = function.schema.name;
    _functions[name] = function;
    (_categoryIndex[category ?? 'uncategorized'] ??= {}).add(name);
  }

  /// Unregisters the function with [name].
  void unregister(String name) => _functions.remove(name);

  /// Invokes a registered host function by [name] directly from Dart.
  ///
  /// When [onEvent] is provided, any [BridgeEvent] the handler emits via
  /// `HostContext.emit` / `HostContext.emitText` is delivered to the callback
  /// before the returned future completes. When [onEvent] is omitted, emissions
  /// are dropped (direct-Dart calls have no stream). Stream wrappers registered
  /// by extensions apply to Python-`execute` runs only and are NOT applied to
  /// direct invocations.
  ///
  /// Callback exceptions are logged via the bridge logger and swallowed.
  Future<Object?> invokeHostFunction(
    String name,
    Map<String, Object?> args, {
    void Function(BridgeEvent)? onEvent,
  }) {
    final fn = _functions[name];
    if (fn == null) throw ArgumentError('Unknown host function: $name');
    final validatedArgs = fn.schema.mapAndValidate(
      const [],
      args.map((k, v) => MapEntry(k, MontyValue.fromDart(v))),
    );
    void sink(BridgeEvent event) {
      if (onEvent == null) return;
      try {
        onEvent(event);
      } on Object catch (err, st) {
        _log.error(
          'invokeHostFunction onEvent callback threw',
          error: err,
          stackTrace: st,
          attributes: {'name': name},
        );
      }
    }

    final ctx = HostContext(
      emit: sink,
      executionId: name,
      os: osHandler,
      parent: _runtime,
      subExecute: _defaultSubExecute,
    );

    return fn.handler!(validatedArgs, ctx);
  }
}
