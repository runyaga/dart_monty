# dart_monty_bridge

Part of [dart_monty](https://github.com/runyaga/dart_monty) — pure Dart bindings for [Monty](https://github.com/pydantic/monty), a restricted, sandboxed Python interpreter built in Rust.

[Live Demo](https://runyaga.github.io/dart_monty/) | [GitHub](https://github.com/runyaga/dart_monty) | [Monty](https://github.com/pydantic/monty)

<img src="https://raw.githubusercontent.com/runyaga/dart_monty/main/docs/bob.png" alt="Bob" height="18"> This package is co-designed by human and AI — nearly all code is AI-generated.

**High-level bridge layer** for dart_monty. Provides host function infrastructure, the default bridge implementation, event loop support, and a plugin system (`PluginRegistry` + `MontyPlugin`) for modular host function bundles.

## Install

```yaml
dependencies:
  dart_monty_bridge: ^0.3.0
```

## Key Types

| Type | Description |
|------|-------------|
| `MontyBridge` | Abstract bridge interface for executing Python code with host functions. |
| `DefaultMontyBridge` | Default implementation orchestrating the start/resume loop. |
| `EventLoopBridge` | Bridge with event loop support (`wait_for_event`, `render_ui`). |
| `PluginRegistry` | Collects `MontyPlugin`s with namespace validation and collision detection. |
| `MontyPlugin` | Extension point for modular host function bundles with lifecycle hooks. |
| `HostFunction` | A single callable host function with schema and handler. |
| `HostFunctionSchema` | Metadata (name, description, params) for a host function. |
| `BridgeEvent` | Sealed event hierarchy emitted during execution. |
