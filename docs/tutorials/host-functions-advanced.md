# Host Functions -- Advanced

This guide covers the `SandboxExtension` for spawning child Python
interpreters, depth and concurrency limits, resource limits per child,
handle lifecycle management, and production patterns.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md) first.

## SandboxExtension

`SandboxExtension` is a `MontyExtension` that lets parent Python code spawn
child Python scripts in separate Monty interpreter instances. Each child
gets its own `MontyPlatform` and `PlatformBridge` -- fully isolated
interpreter state.

### Why Isolated Children

Use cases for child interpreters:

- **Parallel computation:** Fan out work across multiple interpreters
  and collect results.
- **Untrusted code execution:** Run user-supplied code in a constrained
  child with strict resource limits.
- **Recursive scripting:** A script spawns sub-scripts that may
  themselves spawn further children (bounded by depth limits).
- **Fault isolation:** A failing child does not crash the parent.

### Creating a SandboxExtension

```dart
final extension = SandboxExtension(
  platformFactory: () async => MontyFfi(),
  maxChildren: 16,      // Max concurrent children (default: 16)
  maxDepth: 3,          // Max recursion depth (default: 3)
  childLimits: MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
  ),
);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `platformFactory` | `Future<MontyPlatform> Function()` | required | Creates a fresh platform for each child |
| `childVfsStrategy` | `ChildVfsStrategy` | `isolated` | How the child's filesystem relates to the parent's |
| `maxChildren` | `int` | `16` | Maximum concurrent living children |
| `maxDepth` | `int` | `3` | Maximum recursion depth for nested SandboxExtensions |
| `childLimits` | `MontyLimits?` | `null` | Default resource limits for all children |
| `sandboxBaseDir` | `String?` | `null` | Base directory for per-child working directories |
| `systemPromptBuilder` | `ChildSystemPromptBuilder?` | `null` | Builds static system prompt from child context |

### Host Functions Provided

The extension registers these functions under the `sandbox` namespace:

| Function | Description | Parameters |
|----------|-------------|------------|
| `sandbox_spawn(code, timeout_ms?, memory_bytes?, system_prompt?)` | Spawn a child. Returns an integer handle. | `code`: string (required), `timeout_ms`: integer, `memory_bytes`: integer, `system_prompt`: string |
| `sandbox_await(handle)` | Wait for a child to complete. Returns its result. | `handle`: integer |
| `sandbox_await_all(handles)` | Wait for multiple children. Returns list of results. | `handles`: list |
| `sandbox_is_alive(handle)` | Check if a child is still running. Returns boolean. | `handle`: integer |
| `sandbox_free(handle)` | Release a completed child's handle. | `handle`: integer |
| `sandbox_get_output(handle)` | Get a completed child's print output. | `handle`: integer |
| `sandbox_gather(handles)` | Wait for multiple children. Returns list of dicts with handle, value, and output. | `handles`: list |

### Handle Lifecycle

Each `sandbox_spawn()` returns an integer handle. Handles follow a
strict lifecycle:

```text
spawn  ->  alive  ->  completed  ->  freed
```

**Rules:**

- `sandbox_await(handle)` blocks until the child completes or fails.
- `sandbox_free(handle)` releases the handle's resources. It throws
  `StateError` if the child is still alive -- you must await first.
- `sandbox_get_output(handle)` returns the child's captured `print()`
  output as a string (or `null` if no output).
- Unknown handles throw `ArgumentError`.

**Warning:** You should call `sandbox_free()` on completed
handles that you no longer need to free memory and concurrency slots.

## Depth and Concurrency Limits

### Depth Limits

Children automatically inherit extensions (including `SandboxExtension`)
from the parent via the `createChildInstance()` mechanism.

When `currentDepth >= maxDepth`, `sandbox_spawn()` throws `StateError`.

### Concurrency Limits

`maxChildren` limits the number of **alive** children at any time.
When the limit is reached, `sandbox_spawn()` throws `StateError`.

## Extension Inheritance

`SandboxExtension` relies on the parent `ExtensionCoordinator` to compose
the child's environment. When spawning, it calls `coordinator.spawnChild()`,
which iterates through all registered extensions and calls
`MontyExtension.createChildInstance()` on each.

Extensions that return a new instance are registered on the child's bridge.
Extensions that return `null` are excluded.

## Child System Prompts

`SandboxExtension` supports injecting custom system prompts into child
sandboxes via two layers:

### Layer 1: Infrastructure Builder (static, from Dart)

The `systemPromptBuilder` callback produces static content:

```dart
SandboxExtension(
  platformFactory: () async => MontyFfi(),
  systemPromptBuilder: (context) =>
      'You are child ${context.childId}. '
      'Your workspace is ${context.workingDirectory}.',
)
```

### Layer 2: Parent LLM Fragment (dynamic, from Python)

The `system_prompt` parameter on `sandbox_spawn` lets the parent LLM
inject instructions at runtime.

### Concatenation Order

The final prompt is: `builder output + runtime system_prompt`.

## Disposal and Cleanup

When `SandboxExtension.onDispose()` is called, all living children are
torn down (disposed).

When a child completes, the extension performs cleanup: the child's bridge,
platform, and extension registry are disposed.
