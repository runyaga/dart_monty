import 'package:dart_monty/src/extension/extension.dart' show MontyExtension;
import 'package:dart_monty/src/host/context.dart';
import 'package:dart_monty/src/host/function_surface.dart';
import 'package:dart_monty/src/host/schema.dart';
import 'package:dart_monty/src/runtime/backend_kind.dart';
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
  /// When only one backend slot is populated, `AttachContext.register()`
  /// silently skips the function on the other backend — no
  /// `supportedBackends` declaration required.
  ///
  /// Set [isInfra] to `true` for orchestration builtins that should bypass
  /// the interceptor (e.g. introspection, internal routing).
  ///
  /// [childPropagation] controls whether this function is visible inside
  /// child sandboxes spawned from the parent runtime. Defaults to
  /// [ChildPropagation.exclude] — children see only extension
  /// functions, not ad-hoc functions registered via `extraFunctions:`.
  const HostFunction({
    required this.schema,
    HostFunctionHandler? handler,
    HostFunctionHandler? ffiHandler,
    HostFunctionHandler? wasmHandler,
    this.isInfra = false,
    this.surfaces = const {FunctionSurface.python},
    this.childPropagation = ChildPropagation.exclude,
  }) : ffiHandler = ffiHandler ?? handler,
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
  /// Defaults to `{FunctionSurface.python}`. Add [FunctionSurface.llm] to
  /// expose the schema via `MontyRuntime.exposedSchemas`.
  final Set<FunctionSurface> surfaces;

  /// Whether this function is visible inside child sandboxes spawned from
  /// the runtime it is attached to.
  ///
  /// Only applies to functions registered via the `extraFunctions:` slot on
  /// `ExtensionCoordinator.attachTo` — extension-provided functions are
  /// governed by [MontyExtension.childPolicy] instead.
  final ChildPropagation childPropagation;

  /// The handler for the current backend, or `null` if not available.
  ///
  /// `AttachContext.register()` uses this to silently skip functions that have
  /// no implementation for the running backend.
  HostFunctionHandler? get handler =>
      currentBackendKind == MontyBackendKind.ffi ? ffiHandler : wasmHandler;
}

/// Whether an ad-hoc [HostFunction] registered via `extraFunctions:` should
/// be re-registered inside child sandboxes.
enum ChildPropagation {
  /// Do not forward this function to children. The default — children get
  /// a clean surface and cannot accidentally inherit parent-only tools.
  exclude,

  /// Re-register this function on every spawned child coordinator.
  inherit,
}
