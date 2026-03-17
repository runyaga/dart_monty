# Changelog

## 0.5.0

### Added

- `SandboxPlugin`: child system prompt injection via `ChildSystemPromptBuilder`
  callback — infrastructure can set identity/workspace context per child (#231)
- `PluginRegistry.attachTo`: accept `extraFunctions` for standalone host
  functions outside any plugin namespace (#222)

### Fixed

- `JsonPlugin`: standardize parameter names — `text`/`value` → `data` for
  consistency across `json_loads`, `json_dumps`, `json_get` (#229)

## 0.4.1

- Add `example/example.dart` demonstrating plugin creation and registry setup

## 0.4.0

### Breaking

- Remove `CompositePlugin` mixin and `PluginRef<T>`. Use constructor injection
  for inter-plugin dependencies.
- Rename `IsolatePlugin` to `SandboxPlugin` — the plugin creates isolated Monty
  interpreter instances, not Dart isolates.
- Plugins no longer accept a `Logger` constructor parameter. Logging is injected
  automatically via `MontyPlugin.logger` (`BridgeLogger`) by `PluginRegistry`
  before `onRegister()`.
- Bump `dart_monty_platform_interface` to `^0.8.0`, `struct_log` to `^0.3.0`.

### Added

- `BridgeMiddleware` with sealed `CallRole` — intercept, modify, or block host
  function calls with pre/post hooks and role-based security.
- `JsonPlugin` — `json_parse`, `json_stringify`, `json_query` host functions.
- `TemplatePlugin` — `template_render` host function with Mustache-style
  templates.
- `MessageBusPlugin` — `bus_send`/`bus_receive` for parent-child communication.
- `invokeHostFunction()` on `MontyBridge` for Dart-side tool dispatch.
- `sandbox_gather` host function for output attribution from child sandboxes.
- `ChildSpawnContext` for per-child filesystem isolation in `SandboxPlugin`.
- `extraFunctions` parameter on `PluginRegistry.attachTo()` for ad-hoc host
  functions without a full plugin.
- `BridgeLogger` abstract interface with `NullBridgeLogger` default.
- `StructLogBridgeLogger` adapter with hierarchical `.child()` scoping and
  cascading `close()`.
- `PluginRegistry` propagates `bridge.logger.child(plugin.namespace)` to each
  plugin and uses `bridge.logger.child('registry')` internally.
- `SandboxPlugin` child bridges receive `logger.child('child.$id')`.
- `help()` resolves bare function names without namespace prefix.
- `SandboxPlugin.createChildInstance()` for plugin inheritance in child bridges.

### Fixed

- Child bridges use `useFutures: false` to prevent hangs.
- Child isolate errors surface as tool failures instead of crashing parent.
- Plugin registration failure logging with structured context.

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
