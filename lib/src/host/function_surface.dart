import 'package:dart_monty/src/host/function.dart' show HostFunction;

/// The surfaces on which a [HostFunction] is visible.
///
/// Defaults to `{FunctionSurface.python}` — existing extensions register as
/// Python-only with no change. Add [FunctionSurface.llm] to expose the
/// function schema via `MontyRuntime.exposedSchemas`.
enum FunctionSurface {
  /// Callable from Python scripts via the host-function dispatch bridge.
  python,

  /// Schema exposed to LLM consumers via `MontyRuntime.exposedSchemas`.
  llm,
}
