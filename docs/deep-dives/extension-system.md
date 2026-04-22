# Extension System

The dart\_monty extension system lets you expose Dart functions to Python code
running in the Monty sandbox. This guide suite covers the system from
first principles through production patterns.

## Guides

| Level | Document | What you will learn |
|-------|----------|---------------------|
| Intro | [Host Functions Intro](../tutorials/host-functions-intro.md) | What host functions are, why they exist, and a 3-line "hello world" |
| Beginner | [Host Functions Beginner](../tutorials/host-functions-beginner.md) | `HostFunctionSchema`, typed params, validation, error handling, `BridgeEvent` stream |
| Intermediate | [Host Functions Intermediate](../tutorials/host-functions-intermediate.md) | `MontyExtension`, `ExtensionCoordinator`, namespaces, lifecycle hooks, introspection, `EventLoopExtension` |
| Advanced | [Host Functions Advanced](../tutorials/host-functions-advanced.md) | `SandboxExtension`, child spawning, depth/concurrency limits, production patterns |
| Middleware | [Bridge Middleware](../tutorials/bridge-middleware.md) | `BridgeMiddleware`, sealed `CallRole`, onion chain, grounding, rate limiting, why `CompositeExtension` was removed |

## Architecture at a Glance

```text
+--------------------------------------------------+
|  ExtensionCoordinator + MontyExtension                    |  namespace validation,
|  (dart_monty_bridge)                             |  lifecycle, introspection
+--------------------------------------------------+
|  BridgeMiddleware + CallRole                     |  onion-style policy chain
|  (dart_monty_bridge)                             |  (grounding, telemetry, ACL)
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
