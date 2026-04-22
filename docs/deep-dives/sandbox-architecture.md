# Sandbox Architecture

## Overview

`SandboxExtension` spawns Python scripts in isolated child interpreters.
Each child gets its own `MontyPlatform`, `PlatformBridge`, and
an `ExtensionCoordinator` for inherited tools. The parent Python script
controls children via host functions.

**Cross-platform:** Fully supported on both native (FFI) and web (WASM).
On native, each child gets a fresh `MontyFfi` instance. On WASM, each
child gets its own `MontyRepl` session inside a shared Web Worker,
ensuring memory isolation and concurrency without needing multiple Workers.

| | Native (FFI) | Web (WASM) |
|---|---|---|
| Child interpreter | Fresh `MontyFfi` (same isolate) | Fresh `MontyRepl` (shared Worker) |
| Memory isolation | Separate Rust interpreter state | Separate Rust REPL heap |
| Parallelism | Sequential (same event loop) | Concurrent (shared Worker loop) |
| Extension inheritance | Instance-based (via coordinator) | Instance-based (via coordinator) |

## Host Functions

- `sandbox_spawn(code, timeout_ms?, memory_bytes?, system_prompt?)` --
  Spawn child interpreter, returns integer handle
- `sandbox_await(handle)` --
  Wait for child to complete, returns result
- `sandbox_await_all(handles)` --
  Wait for multiple children
- `sandbox_gather(handles)` --
  Wait and return attributed results (dict with handle, value, output)
- `sandbox_is_alive(handle)` --
  Check if child is still running
- `sandbox_free(handle)` --
  Release completed child resources
- `sandbox_get_output(handle)` --
  Get child's captured print output

## Usage

```python
# Spawn a child that computes something
h = sandbox_spawn(code='sum(range(100))')

# Wait for the result
result = sandbox_await(h)  # 4950

# Parallel execution
h1 = sandbox_spawn(code='2 ** 16')
h2 = sandbox_spawn(code='3 ** 10')
results = sandbox_gather(handles=[h1, h2])
# [{'handle': 0, 'value': 65536, 'output': None},
#  {'handle': 1, 'value': 59049, 'output': None}]
```

## Isolation Model

Each child gets:

- **Own `MontyPlatform`** — fresh interpreter instance via `platformFactory`
- **Own `PlatformBridge`** — independent dispatch loop, middleware, events
- **Own `ExtensionCoordinator`** — inherited from parent via `spawnChild`
- **Own VFS** (optional) — controlled by `childVfsStrategy` (isolated, shared, or none)
- **Shared time/env** — inherited from parent's OS handlers

Children cannot access the parent's heap, globals, or variables.
Communication happens through return values, print output, and the
`MessageBusExtension` (if registered).

## Extension Inheritance

`SandboxExtension` relies on the parent `ExtensionCoordinator` to compose
the child's environment. When spawning, it calls `coordinator.spawnChild()`,
which iterates through all registered extensions and calls
`MontyExtension.createChildInstance()` on each.

### Example Configuration

```dart
final session = MontyRuntime(
  extensions: [
    JinjaTemplateExtension(),
    MessageBusExtension(),
    SandboxExtension(
      platformFactory: () async => MontyFfi(),
      childVfsStrategy: ChildVfsStrategy.isolated,
    ),
  ],
);
```

Rules:

- `SandboxExtension` itself is typically **skipped** during inheritance
  to prevent runaway recursion unless `maxDepth` allows it.
- Extensions return `null` from `createChildInstance()` to opt out.
- Extensions must return a **new instance** or a compatible proxy,
  never `this` (to ensure lifecycle isolation).

## Grandchildren

Children can spawn their own children (grandchildren) if they inherit the
`SandboxExtension`. This is controlled by `maxDepth` (default: 3).

- `currentDepth=0` (parent) can spawn children
- `currentDepth=1` (child) can spawn grandchildren
- `currentDepth >= maxDepth` raises `StateError` during `sandbox_spawn`.

## OS Handler / Filesystem Inheritance

The `childVfsStrategy` selects how the child's filesystem relates to the
parent's:

- **`ChildVfsStrategy.isolated`** (default) — Each child gets a fresh,
  empty `memoryFsHandler()`.
- **`ChildVfsStrategy.shared`** — Children share the parent's `Path.`
  handler (dangerous but useful for shared workspaces).
- **`ChildVfsStrategy.none`** — Children have no filesystem access.

## Architecture Diagram

```text
MontyRuntime
  └── PlatformBridge (parent)
        ├── JinjaTemplateExtension (tmpl_render)
        ├── MessageBusExtension (msg_send, msg_recv, ...)
        └── SandboxExtension
              ├── sandbox_spawn → calls coordinator.spawnChild():
              │     └── PlatformBridge (child)
              │           ├── JinjaTemplateExtension (inherited instance)
              │           └── SandboxExtension (depth+1, if depth < maxDepth)
              │                 └── sandbox_spawn → creates:
              │                       └── PlatformBridge (grandchild)
              │                             └── ...
              ├── sandbox_await → awaits child.completer.future
              ├── sandbox_gather → Future.wait(children)
              └── sandbox_free → disposes child resources
```
