import 'dart:async';

import 'package:dart_monty/src/extension/extension.dart' show MontyExtension;
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// How the bridge dispatches calls to a [HostFunction].
enum DispatchMode {
  /// Exposes a regular Python call and settles the handler before Python
  /// continues in FIFO order.
  sync,

  /// Exposes an awaitable for Python `await` and concurrent
  /// `asyncio.gather` calls.
  future,
}

/// Async handler that receives validated named arguments and a [HostContext].
typedef HostFunctionHandler =
    Future<MontyValue> Function(Map<String, MontyValue> args, HostContext ctx);

/// Accepts any convertible Dart result for an upstream-compatible host
/// function.
typedef ParityHostFunctionHandler =
    FutureOr<Object?> Function(Map<String, MontyValue> args, HostContext ctx);

/// Combines a Python schema with per-backend Dart handlers, including functions
/// admitted to children by [MontyExtension.childPolicy].
@immutable
class HostFunction {
  /// Configures backend handlers and their Python dispatch behavior.
  const HostFunction({
    required this.schema,
    HostFunctionHandler? handler,
    HostFunctionHandler? ffiHandler,
    HostFunctionHandler? wasmHandler,
    this.dispatch = DispatchMode.sync,
  }) : ffiHandler = ffiHandler ?? handler,
       wasmHandler = wasmHandler ?? handler,
       _ffiParityHandler = null,
       _wasmParityHandler = null,
       _isParity = false;

  /// Uses upstream-compatible binding and result-conversion failures.
  const HostFunction.parity({
    required this.schema,
    ParityHostFunctionHandler? handler,
    ParityHostFunctionHandler? ffiHandler,
    ParityHostFunctionHandler? wasmHandler,
    this.dispatch = DispatchMode.sync,
  }) : ffiHandler = null,
       wasmHandler = null,
       _ffiParityHandler = ffiHandler ?? handler,
       _wasmParityHandler = wasmHandler ?? handler,
       _isParity = true;

  /// Describes name, parameters, and types.
  final HostFunctionSchema schema;

  /// Handles native calls when non-null.
  final HostFunctionHandler? ffiHandler;

  /// Handles browser calls when non-null.
  final HostFunctionHandler? wasmHandler;

  /// Selects ordered or concurrent Python dispatch.
  final DispatchMode dispatch;

  final ParityHostFunctionHandler? _ffiParityHandler;

  final ParityHostFunctionHandler? _wasmParityHandler;

  final bool _isParity;

  /// Selects the handler for the current backend.
  HostFunctionHandler? get handler =>
      currentBackendKind == MontyBackendKind.ffi ? ffiHandler : wasmHandler;
}

/// Internal parity-mode accessors for [HostFunction].
@internal
extension HostFunctionParityInternal on HostFunction {
  /// Reports construction through [HostFunction.parity].
  bool get isParity => _isParity;

  /// The parity handler for the current backend, or `null` if not available.
  ParityHostFunctionHandler? get parityHandler =>
      currentBackendKind == MontyBackendKind.ffi
      ? _ffiParityHandler
      : _wasmParityHandler;

  /// Whether a legacy or parity handler is available on the current backend.
  bool get hasActiveHandler => (_isParity ? parityHandler : handler) != null;
}
