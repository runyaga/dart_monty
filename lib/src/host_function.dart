import 'package:dart_monty/src/host_context.dart';
import 'package:dart_monty/src/host_function_schema.dart';
import 'package:dart_monty/src/monty_backend_kind.dart';
import 'package:dart_monty/src/tool_surface.dart';
import 'package:meta/meta.dart';

/// Async handler that receives validated named arguments and a [HostContext].
typedef HostFunctionHandler =
    Future<Object?> Function(Map<String, Object?> args, HostContext ctx);

/// A host function: schema + per-backend handlers + optional infra flag.
@immutable
class HostFunction {
  /// Creates a [HostFunction].
  ///
  /// Pass [handler] as a convenience shortcut to install the same
  /// implementation on both [ffiHandler] and [wasmHandler]. Use the
  /// backend-specific slots directly when the implementation differs per
  /// platform (e.g. `dart:js_interop` on WASM, native packages on FFI).
  ///
  /// When only one backend slot is populated, `PluginHost.register()` silently
  /// skips the function on the other backend — no `supportedBackends`
  /// declaration required.
  ///
  /// Set [isInfra] to `true` for orchestration builtins that should bypass
  /// the interceptor (e.g. introspection, internal routing).
  const HostFunction({
    required this.schema,
    HostFunctionHandler? handler,
    HostFunctionHandler? ffiHandler,
    HostFunctionHandler? wasmHandler,
    this.isInfra = false,
    this.surfaces = const {ToolSurface.python},
  })  : ffiHandler = ffiHandler ?? handler,
        wasmHandler = wasmHandler ?? handler;

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

  /// When `true`, calls to this function bypass the interceptor.
  final bool isInfra;

  /// Which surfaces this function is visible on.
  ///
  /// Defaults to `{ToolSurface.python}`. Add [ToolSurface.llm] to expose
  /// the schema via `MontyRuntime.llmSchemas`.
  final Set<ToolSurface> surfaces;

  /// The handler for the current backend, or `null` if not available.
  ///
  /// `PluginHost.register()` uses this to silently skip functions that have
  /// no implementation for the running backend.
  HostFunctionHandler? get handler =>
      currentBackendKind == MontyBackendKind.ffi ? ffiHandler : wasmHandler;
}
