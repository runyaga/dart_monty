# Changelog

## 0.2.2

- **DEPRECATION**: `HostFunctionRegistry` is deprecated. Use `PluginRegistry`
  with `MontyPlugin` instead for namespace-validated function grouping.
- **BREAKING**: Remove `struct_log` re-export from barrel. If you use `Logger`
  or `LogManager` from `dart_monty_bridge`, import
  `package:struct_log/struct_log.dart` directly instead.

## 0.2.1

- Add `printOutput` field to `BridgeRunError` so failed children preserve print output for debugging.
- Add `isolate_free` host function to release completed child handles (prevents memory leak).
- Fix `cancel()` to dispose child plugin registry (prevents resource leak).

## 0.2.0

- `IsolatePlugin` — spawn Python scripts in isolated interpreter instances.
  - `isolate_spawn(code)` — start a child with optional timeout/memory limits.
  - `isolate_await(handle)` / `isolate_await_all(handles)` — wait for results.
  - `isolate_is_alive(handle)` — poll child status.
  - `isolate_cancel(handle)` — cancel a running child.
- Depth limiting (`maxDepth`) prevents unbounded recursion.
- Concurrency limiting (`maxChildren`) caps concurrent children (default 16).
- `childPluginRegistryFactory` optionally wires plugins into child bridges.
- `childLimits` applies resource limits to all child interpreters.

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
