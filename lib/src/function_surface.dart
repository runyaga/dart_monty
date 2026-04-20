/// The surfaces on which a [HostFunction] is visible.
///
/// Defaults to `{FunctionSurface.python}` — existing extensions register as
/// Python-only with no change. Add [FunctionSurface.llm] to expose the
/// function schema via `MontyRuntime.llmSchemas`.
enum FunctionSurface {
  /// Callable from Python scripts via the host-function dispatch bridge.
  python,

  /// Schema exposed to LLM consumers via `MontyRuntime.llmSchemas`.
  llm,
}
