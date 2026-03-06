# Changelog

## 0.1.0

- Initial release of `dart_monty_bridge`.
- `MontyBridge` abstract interface for Python↔Dart host function dispatch.
- `DefaultMontyBridge` — full start/resume loop with futures support.
- `EventLoopBridge` — bidirectional Python/Dart state loop via
  `wait_for_event` / `render_ui` host functions.
- `HostFunction`, `HostFunctionSchema`, `HostParam`, `HostParamType` —
  typed parameter system with validation and coercion.
- `HostFunctionRegistry` — category-based function grouping with
  introspection builtins.
- `MontyPlugin` — abstract namespace-validated plugin interface with
  lifecycle hooks (`onRegister`, `onDispose`).
- `PluginRegistry` — namespace validation, prefix enforcement, collision
  detection, `attachTo`, `disposeAll`, `generateSystemPrompt`.
- `BridgeEvent` sealed hierarchy — 15 event types covering run lifecycle,
  tool calls, text output, and event loop.
- Strict argument validation: rejects extra positional args and unknown
  kwargs from LLM-generated calls.
- Host handler errors (`Error` and `Exception`) caught and returned to
  Python instead of crashing the script.
- Print buffer preserved on infrastructure exceptions.
