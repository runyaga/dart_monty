# Changelog

## 0.4.0

- **BREAKING**: Remove `CompositePlugin` mixin and `PluginRef<T>`. Use
  constructor injection instead for inter-plugin dependencies.
- `PluginRegistry.attachTo()` calls `onRegister()` in registration order.
- `PluginRegistry.disposeAll()` calls `onDispose()` in reverse registration
  order.
- **BREAKING**: Plugins no longer accept a `Logger` constructor parameter.
  Logging is now injected automatically via `MontyPlugin.logger` (a
  `BridgeLogger` field, default `NullBridgeLogger`) by `PluginRegistry`
  before `onRegister()`.
- Add `BridgeLogger get logger` to `MontyBridge` abstract interface.
- Add `StructLogBridgeLogger` — batteries-included adapter wrapping
  struct_log's `Logger`/`LogManager` with hierarchical `.child()` scoping
  and cascading `close()`.
- `DefaultMontyBridge` defaults to `StructLogBridgeLogger.root(LogManager.instance)`.
- `PluginRegistry` propagates `bridge.logger.child(plugin.namespace)` to
  each plugin and uses `bridge.logger.child('registry')` internally.
- `SandboxPlugin` child bridges receive `logger.child('child.$id')`.
- Bump `dart_monty_platform_interface` to `^0.8.0`, `struct_log` to `^0.3.0`.

## 0.3.1

- Remove `dependency_overrides` for clean pub.dev publishing
- Switch `struct_log` from git dependency to `^0.1.0` hosted

## 0.3.0

- **BREAKING**: Remove deprecated `HostFunctionRegistry` class and barrel export.
  Use `PluginRegistry` with `MontyPlugin` instead.
- Fix `PluginRegistry.disposeAll()` to dispose all plugins even if one throws,
  collecting errors into a single `StateError`.
- Fix `PluginRegistry.attachTo()` to attach all plugins even if `onRegister()`
  throws, collecting errors into a single `StateError`.

## 0.2.2

- **DEPRECATION**: `HostFunctionRegistry` is deprecated. Use `PluginRegistry`
  with `MontyPlugin` instead for namespace-validated function grouping.
- **BREAKING**: Remove `struct_log` re-export from barrel. If you use `Logger`
  or `LogManager` from `dart_monty_bridge`, import
  `package:struct_log/struct_log.dart` directly instead.

## 0.2.1

- Add `printOutput` field to `BridgeRunError` so failed children preserve print output for debugging.
- Add `sandbox_free` host function to release completed child handles (prevents memory leak).
- Fix `cancel()` to dispose child plugin registry (prevents resource leak).

## 0.2.0

- `SandboxPlugin` — spawn Python scripts in isolated interpreter instances.
  - `sandbox_spawn(code)` — start a child with optional timeout/memory limits.
  - `sandbox_await(handle)` / `sandbox_await_all(handles)` — wait for results.
  - `sandbox_is_alive(handle)` — poll child status.
  - `sandbox_cancel(handle)` — cancel a running child.
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
