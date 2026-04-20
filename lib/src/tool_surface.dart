/// The surfaces on which a [HostFunction] is visible.
///
/// Defaults to `{ToolSurface.python}` — existing plugins register as
/// Python-only with no change. Add [ToolSurface.llm] to expose the function
/// schema to the LLM via `MontyRuntime.llmSchemas`.
enum ToolSurface {
  /// Callable from Python scripts via the host-function dispatch bridge.
  python,

  /// Schema exposed to the LLM via `MontyRuntime.llmSchemas`.
  llm,
}
