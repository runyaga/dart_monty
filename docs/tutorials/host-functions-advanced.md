# Host Functions -- Advanced

This guide covers the `SandboxExtension` for spawning child Python
interpreters, depth and concurrency limits, resource limits per child,
handle lifecycle management, and production patterns.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md) first.

## SandboxExtension

`SandboxExtension` is a `MontyExtension` that lets parent Python code spawn
child Python scripts in separate Monty interpreter instances. Each child
gets its own `MontyPlatform` and `DefaultMontyBridge` -- fully isolated
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

### Creating an SandboxExtension

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

final extension = SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  maxChildren: 16,      // Max concurrent children (default: 16)
  maxDepth: 3,          // Max recursion depth (default: 3)
  currentDepth: 0,      // This extension's depth level (default: 0)
  childLimits: MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
  ),
);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `platformFactory` | `Future<MontyPlatform> Function()` | required | Creates a fresh platform for each child |
| `childVfsStrategy` | `ChildVfsStrategy` | `ChildVfsStrategy.isolated` | How the child's `Path.` handler relates to the parent's |
| `maxChildren` | `int` | `16` | Maximum concurrent living children |
| `maxDepth` | `int` | `3` | Maximum recursion depth for nested SandboxExtensions |
| `currentDepth` | `int` | `0` | This extension's current depth in the recursion tree |
| `childLimits` | `MontyLimits?` | `null` | Default resource limits for all children |
| `sandboxBaseDir` | `String?` | `null` | Base directory for per-child working directories |
| `systemPromptBuilder` | `ChildSystemPromptBuilder?` | `null` | Builds static system prompt from child context |

### What children inherit (and what they don't)

Children created by `sandbox_spawn` automatically inherit the host
functions provided by the parent runtime's **built-in
`MontyExtension`** instances — `tmpl_render`, `msg_send`,
`sandbox_spawn` itself (subject to `maxDepth`), etc.

Children do **not** inherit host functions you registered directly on
the parent runtime via `runtime.register(HostFunction(...))`. Those
are runtime-local, not extension-attached, and the child's own
runtime has no record of them. If a child script needs to call a
custom host function:

- Wrap it in a `MontyExtension` and add it to the parent runtime's
  `extensions` list, OR
- Compute the value on the parent and pass it into the child's `code`
  string at spawn time (e.g. interpolate a JSON literal into the
  child source).

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

### Basic Usage from Python

```python
# Spawn two children
h1 = sandbox_spawn("2 ** 10")
h2 = sandbox_spawn("3 ** 7")

# Wait for both
results = sandbox_await_all([h1, h2])
# results == [1024, 2187]

# Clean up
sandbox_free(h1)
sandbox_free(h2)
```

### Handle Lifecycle

Each `sandbox_spawn()` returns an integer handle. Handles follow a
strict lifecycle:

```text
spawn  ->  alive  ->  completed  ->  freed
```

**Rules:**

- `sandbox_await(handle)` blocks until the child completes or fails.
  If the child failed, it raises an error with the child's error message.
- `sandbox_free(handle)` releases the handle's resources. It throws
  `StateError` if the child is still alive -- you must await first.
- `sandbox_get_output(handle)` returns the child's captured `print()`
  output as a string (or `null` if no output). Throws `StateError` if
  the child is still running.
- `sandbox_is_alive(handle)` returns `true` if the child is still
  executing.
- Unknown handles throw `ArgumentError`.

**Warning:** You must call `sandbox_free()` on every completed
handle. Handles are never garbage collected automatically.
Failing to free handles causes a silent memory leak (the `_ChildHandle`
and its captured output remain in memory) and will eventually exhaust
`maxChildren`, preventing new children from being spawned.

### Per-Child Resource Limits

Children can override the default `childLimits` at spawn time:

```python
# Use default limits from childLimits
h1 = sandbox_spawn("expensive_computation()")

# Override timeout for this specific child
h2 = sandbox_spawn("slow_task()", timeout_ms=30000)

# Override memory for this specific child
h3 = sandbox_spawn("memory_heavy()", memory_bytes=50000000)

# Override both
h4 = sandbox_spawn("big_slow()", timeout_ms=60000, memory_bytes=100000000)
```

When `timeout_ms` or `memory_bytes` are specified at spawn time, they
override the corresponding fields in `childLimits`. Unspecified fields
fall back to the `childLimits` defaults. If `childLimits` is `null`
and no per-child overrides are given, the child runs without resource
constraints.

The `MontyLimits` fields that can be constrained:

| Field | Description |
|-------|-------------|
| `timeoutMs` | Maximum execution time in milliseconds |
| `memoryBytes` | Maximum memory usage in bytes |
| `stackDepth` | Maximum Python call stack depth |

Note that `stackDepth` is not overridable per-child from Python -- it
uses the value from `childLimits`.

## Depth and Concurrency Limits

### Depth Limits

`maxDepth` caps how deep nested `sandbox_spawn` calls can go;
`currentDepth` tracks where in the recursion this extension sits.
A child runtime that itself wires `SandboxExtension` (with
`currentDepth: parent + 1`) is what makes grandchildren possible:

```dart
final root = SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  maxDepth: 3,
  currentDepth: 0,
);
```

When `currentDepth >= maxDepth`, `sandbox_spawn()` throws `StateError`
with the message `"Maximum sandbox recursion depth (N) exceeded."`.

### Concurrency Limits

`maxChildren` limits the number of **alive** children at any time.
When the limit is reached, `sandbox_spawn()` throws `StateError` with
the message `"Maximum concurrent children (N) reached."`.

Freed children do not count against the limit. After
`sandbox_free(handle)`, the slot is available for new children.

## What children inherit from the parent runtime

Children created by `sandbox_spawn` automatically get the host
functions provided by **built-in `MontyExtension` instances** on the
parent — `tmpl_render` (from `JinjaTemplateExtension`), `msg_send`
(from `MessageBusExtension`), `sandbox_spawn` itself (subject to
`maxDepth`), etc.

Children do **not** inherit:

- Host functions you registered directly via
  `runtime.register(HostFunction(...))` — these are runtime-local,
  not extension-attached, and the child has no record of them.
- The parent's OS-call handler chain — children get a fresh handler
  per `childVfsStrategy`.

### Workaround: surface custom host functions to children

If a child script needs a custom host function, do one of:

1. **Wrap it in a `MontyExtension`** and add the extension to the
   parent runtime's `extensions` list. The child's runtime will
   automatically register the extension's host functions.
2. **Pre-compute on the parent and pass via the `code` string** — for
   one-shot data, interpolate a JSON literal into the spawn code:
   `sandbox_spawn(code='import json; data = json.loads({json_str!r}); ...')`.

### Per-Child Filesystem Isolation

The `sandboxBaseDir` parameter sets a base directory for per-child
working directories:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  sandboxBaseDir: '/data',
)
```

When set, each child's `ChildSpawnContext.workingDirectory` is computed
as `$sandboxBaseDir/.sandboxes/child_$id` (e.g.,
`/data/.sandboxes/child_0`). The directory is **not** created by
`SandboxExtension` -- consumers (e.g., an `FsExtension.createChildInstance`)
are responsible for creating and managing it.

## Child System Prompts

`SandboxExtension` supports injecting custom system prompts into child
sandboxes via two layers:

### Layer 1: Infrastructure Builder (static, from Dart)

The `systemPromptBuilder` callback produces static, infrastructure-level
prompt content from `ChildSpawnContext`:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  sandboxBaseDir: '/data',
  systemPromptBuilder: (context) =>
      'You are child ${context.childId}. '
      'Your workspace is ${context.workingDirectory}. '
      'Do not access other children\'s data.',
)
```

- Computed from `ChildSpawnContext` (childId, workingDirectory)
- Infrastructure truths that should never be wrong
- Cannot be prompt-injected by the parent LLM
- Return `null` to skip the builder layer for a specific child

### Layer 2: Parent LLM Fragment (dynamic, from Python)

The `system_prompt` parameter on `sandbox_spawn` lets the parent LLM
inject role-specific instructions at runtime:

```python
h = sandbox_spawn(
    "analyze(data)",
    system_prompt="You are the validator. Check results for correctness."
)
```

- Role assignment, task-specific instructions
- The parent LLM's planning decision at runtime
- Optional -- omit if the parent doesn't need to customize

### Concatenation Order

When both layers are present, the builder output comes first
(infrastructure truth), then the runtime fragment (role assignment),
separated by a blank line:

```text
You are child 0. Your workspace is /data/.sandboxes/child_0.

You are the validator. Check results for correctness.
```

### How It Works

The concatenated prompt is injected into the child's
`ExtensionCoordinator.systemPromptPrefix` **after** registry construction.
This setter-based approach guarantees prompt injection regardless of
whether the registry was built by inheritance or a custom factory --
factories cannot accidentally forget to wire the prompt.

If no extensions exist but a prompt is provided, an empty `ExtensionCoordinator`
is created automatically so the prompt (and introspection builtins) are
available to the child.

## Disposal and Cleanup

When `SandboxExtension.onDispose()` is called:

1. All living children are torn down (disposed).
2. Each child's completer is completed with a `StateError`.
3. Unhandled async errors are suppressed (via `future.ignore()`).
4. The children map is cleared.

Disposal is idempotent -- calling `onDispose()` multiple times is safe.

When a child completes (normally or with error), the extension performs
best-effort cleanup: the child's bridge is disposed, its platform is
disposed, and its extension registry (if any) is disposed. Cleanup errors
are swallowed to avoid masking the child's actual result.

## Production Patterns

### Fan-Out / Fan-In

```python
# Fan out work
handles = []
items = ["task_a", "task_b", "task_c", "task_d"]
i = 0
while i < len(items):
    h = sandbox_spawn('process("' + items[i] + '")')
    handles.append(h)
    i = i + 1

# Fan in results
results = sandbox_await_all(handles)

# Clean up all handles
i = 0
while i < len(handles):
    sandbox_free(handles[i])
    i = i + 1
```

### Timeout with Fallback

```python
h = sandbox_spawn("slow_computation()", timeout_ms=5000)
try:
    result = sandbox_await(h)
except:
    # Child timed out or failed
    result = "fallback_value"
sandbox_free(h)
```

### Checking Progress

```python
h = sandbox_spawn("long_running_task()")

# Poll periodically (in practice, do useful work between checks)
while sandbox_is_alive(h):
    # ... do other work ...
    pass

result = sandbox_await(h)
output = sandbox_get_output(h)
sandbox_free(h)
```

## Writing Custom Extensions for Production

### Extension Design Checklist

1. **Namespace:** Choose a short, descriptive namespace (e.g., `db`,
   `http`, `auth`). It must match `[a-z][a-z0-9_]*` and be at most
   32 characters.

2. **Function naming:** All function names must start with
   `{namespace}_`. Keep names descriptive but concise:
   `db_query`, `db_execute`, `db_tables`.

3. **System prompt context:** Provide `systemPromptContext` if your
   extension needs explanation beyond what the function schemas convey.
   This text goes into LLM system prompts via `generateSystemPrompt()`.

4. **Lifecycle hooks:** Use `onRegister()` to initialize resources
   (open connections, load configs). Use `onDispose()` to clean them
   up. Both must be idempotent.

5. **Error handling:** Let exceptions propagate naturally -- the bridge
   converts them to Python errors. Only catch if you need custom
   recovery or cleanup.

6. **Parameter types:** Use the most specific `HostParamType` possible.
   Reserve `any` for genuinely polymorphic parameters. Use
   `jsonSchemaOverride` for complex types that `HostParamType` cannot
   express.

7. **Thread safety:** If your extension holds mutable state, consider
   that `DefaultMontyBridge` processes one execution at a time (it
   throws `StateError` on concurrent `execute()` calls), but futures
   batching means multiple handlers can run concurrently within a
   single execution.

### Multi-Session Patterns

When running multiple bridge sessions (e.g., one per user), each
session needs its own instances:

```dart
Future<(MontyBridge, ExtensionCoordinator)> createSession() async {
  final registry = ExtensionCoordinator()
    ..register(StorageExtension())  // Fresh instance per session
    ..register(MathExtension());

  final bridge = MontyBridge(platform: createPlatformMonty());
  await registry.attachTo(bridge);

  return (bridge, registry);
}

// Each session is fully isolated
final (bridge1, registry1) = await createSession();
final (bridge2, registry2) = await createSession();

// Dispose independently
bridge1.dispose();
await registry1.disposeAll();
```

Each extension instance maintains its own state. Two `StorageExtension`
instances do not share data.

## Futures Batching

When `useFutures: true` (the default) and the platform implements
`MontyFutureCapable`, the bridge dispatches host function calls as
futures. This enables concurrent handler execution within a single
Python execution:

1. Python calls a host function.
2. Instead of blocking until the handler completes, the bridge calls
   `resumeAsFuture()` to tell the platform "this call is pending."
3. Python continues executing. If it calls more host functions before
   using the return value, those are also dispatched as futures.
4. When Python actually **reads** a return value from a host function
   call (e.g., assigns it to a variable, passes it to another function,
   or uses it in an expression), the Monty runtime needs the concrete
   result. At that point the platform emits `MontyResolveFutures` with
   the list of pending call IDs.
5. The bridge awaits all pending handler futures and feeds the results
   back in a batch.

This is transparent to the Python code and the handler implementations.
It only affects execution ordering: handlers may run concurrently if
the platform supports futures.

If a handler throws synchronously (before returning a `Future`), the
bridge catches it immediately and feeds the error back via
`resumeWithError()` to avoid deadlocking the platform.
