import 'dart:async';

import 'package:dart_monty/src/extension/extension.dart' show MontyExtension;
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

/// How the bridge dispatches calls to a [HostFunction].
enum DispatchMode {
  /// The session awaits the handler's Future before Python continues.
  /// Python sees a plain value at the call site, as from a `def`. Use for
  /// functions with FIFO ordering invariants or simple
  /// request-response handlers that don't benefit from concurrency.
  sync,

  /// The handler is core's `coroutine`, as an `async def` host function:
  /// Python gets an awaitable, settled when the handler's Future
  /// completes. Enables `asyncio.gather` parallelism and `await ext()`
  /// from Python.
  future,
}

/// Async handler that receives validated named arguments and a [HostContext].
typedef HostFunctionHandler =
    Future<MontyValue> Function(Map<String, MontyValue> args, HostContext ctx);

/// Handler for [HostFunction.parity] that may return any Dart object or
/// [MontyValue], synchronously or asynchronously.
typedef ParityHostFunctionHandler =
    FutureOr<Object?> Function(Map<String, MontyValue> args, HostContext ctx);

/// A host function: schema + per-backend handlers.
@immutable
class HostFunction {
  /// Creates a [HostFunction].
  ///
  /// Pass [handler] as a convenience shortcut to install the same
  /// implementation on both [ffiHandler] and [wasmHandler]. Use the
  /// backend-specific slots directly when the implementation differs per
  /// platform (e.g. `dart:js_interop` on WASM, native packages on FFI).
  ///
  /// When only one backend slot is populated, `AttachContext.register()`
  /// silently skips the function on the other backend — no
  /// `supportedBackends` declaration required.
  ///
  /// A child sandbox never sees a function registered this way; children
  /// get only the functions of extensions their [MontyExtension.childPolicy]
  /// admits.
  ///
  /// [dispatch] controls whether the bridge dispatches this function
  /// synchronously (default [DispatchMode.sync]) or as a deferred future
  /// ([DispatchMode.future]). Use [DispatchMode.future] only for handlers
  /// that benefit from concurrency (network I/O, `asyncio.gather` patterns).
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

  /// Creates a parity [HostFunction] whose unconvertible return values and
  /// upstream binding errors become Python `TypeError`.
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

  /// Handler for the FFI (native/VM) backend.
  ///
  /// `null` means this function is not registered on the FFI backend.
  final HostFunctionHandler? ffiHandler;

  /// Handler for the WASM (browser) backend.
  ///
  /// `null` means this function is not registered on the WASM backend.
  final HostFunctionHandler? wasmHandler;

  /// How the bridge dispatches calls to this function.
  ///
  /// Defaults to [DispatchMode.sync] — the bridge awaits the handler before
  /// resuming Python. Set to [DispatchMode.future] for handlers that benefit
  /// from concurrent dispatch (e.g. network I/O, `asyncio.gather` callers).
  final DispatchMode dispatch;

  final ParityHostFunctionHandler? _ffiParityHandler;

  final ParityHostFunctionHandler? _wasmParityHandler;

  final bool _isParity;

  /// The handler for the current backend, or `null` if not available.
  ///
  /// `AttachContext.register()` uses this to silently skip functions that have
  /// no implementation for the running backend.
  HostFunctionHandler? get handler =>
      currentBackendKind == MontyBackendKind.ffi ? ffiHandler : wasmHandler;
}

/// Internal parity-mode accessors for [HostFunction].
@internal
extension HostFunctionParityInternal on HostFunction {
  /// Whether this function was created with [HostFunction.parity].
  bool get isParity => _isParity;

  /// Parity handler for the FFI (native/VM) backend.
  ParityHostFunctionHandler? get ffiParityHandler => _ffiParityHandler;

  /// Parity handler for the WASM (browser) backend.
  ParityHostFunctionHandler? get wasmParityHandler => _wasmParityHandler;

  /// The parity handler for the current backend, or `null` if not available.
  ParityHostFunctionHandler? get parityHandler =>
      currentBackendKind == MontyBackendKind.ffi
      ? _ffiParityHandler
      : _wasmParityHandler;

  /// Whether a legacy or parity handler is available on the current backend.
  bool get hasActiveHandler => (_isParity ? parityHandler : handler) != null;
}
