# Plugin System

The dart\_monty plugin system lets you expose Dart functions to Python code
running in the Monty sandbox. This guide suite covers the system from
first principles through production patterns.

## Guides

| Level | Document | What you will learn |
|-------|----------|---------------------|
| Intro | [Host Functions Intro](guides/host-functions-intro.md) | What host functions are, why they exist, and a 3-line "hello world" |
| Beginner | [Host Functions Beginner](guides/host-functions-beginner.md) | `HostFunctionSchema`, typed params, validation, error handling, `BridgeEvent` stream |
| Intermediate | [Host Functions Intermediate](guides/host-functions-intermediate.md) | `MontyPlugin`, `PluginRegistry`, namespaces, lifecycle hooks, introspection, `EventLoopBridge` |
| Advanced | [Host Functions Advanced](guides/host-functions-advanced.md) | `IsolatePlugin`, child spawning, depth/concurrency limits, production patterns |

## Architecture at a Glance

```text
+--------------------------------------------------+
|  PluginRegistry + MontyPlugin                    |  namespace validation,
|  (dart_monty_bridge)                             |  lifecycle, introspection
+--------------------------------------------------+
|  DefaultMontyBridge + HostFunction               |  dispatch loop, event
|  (dart_monty_bridge)                             |  streaming, arg coercion
+--------------------------------------------------+
|  MontyPlatform (start/resume/run)                |  raw platform interface
|  (dart_monty_platform_interface)                 |
+--------------------------------------------------+
|  MontyFfi / MontyWasm                            |  FFI or WASM backend
|  (dart_monty_ffi / dart_monty_wasm)              |
+--------------------------------------------------+
```

Most applications work at the top two layers. Start with the Intro guide
and progress through the levels as your needs grow.
