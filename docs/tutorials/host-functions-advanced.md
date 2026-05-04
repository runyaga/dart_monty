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
| `childExtensionCoordinatorFactory` | `Future<ExtensionCoordinator?> Function(ChildSpawnContext)?` | `null` | Optional: provides extensions to children |
| `parentExtensions` | `List<MontyExtension>` | `const []` | Parent extensions for automatic child inheritance |
| `maxChildren` | `int` | `16` | Maximum concurrent living children |
| `maxDepth` | `int` | `3` | Maximum recursion depth for nested SandboxExtensions |
| `currentDepth` | `int` | `0` | This extension's current depth in the recursion tree |
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

If children also have `SandboxExtension` registered (via
`childExtensionCoordinatorFactory`), they can spawn their own children. The
`maxDepth` and `currentDepth` parameters control how deep this
recursion can go:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  maxDepth: 3,
  currentDepth: 0,
  childExtensionCoordinatorFactory: (context) async {
    final registry = ExtensionCoordinator();
    registry.register(SandboxExtension(
      platformFactory: () async => createPlatformMonty(),
      maxDepth: 3,
      currentDepth: 1,  // One level deeper
    ));
    return registry;
  },
)
```

When `currentDepth >= maxDepth`, `sandbox_spawn()` throws `StateError`
with the message `"Maximum sandbox recursion depth (N) exceeded."`.

### Concurrency Limits

`maxChildren` limits the number of **alive** children at any time.
When the limit is reached, `sandbox_spawn()` throws `StateError` with
the message `"Maximum concurrent children (N) reached."`.

Freed children do not count against the limit. After
`sandbox_free(handle)`, the slot is available for new children.

## Providing Extensions to Children

By default, children only get the introspection builtins (if a
`ExtensionCoordinator` is attached). Use `childExtensionCoordinatorFactory` to
give children access to host functions:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  childExtensionCoordinatorFactory: (context) async {
    final registry = ExtensionCoordinator();
    registry.register(MathExtension());
    registry.register(StorageExtension());
    // Note: do NOT register SandboxExtension here unless you want
    // recursive spawning (and remember to increment currentDepth)
    return registry;
  },
)
```

The factory receives a `ChildSpawnContext` with the child's `childId`
and optional `workingDirectory` -- use these for per-child resource
configuration.

Return `null` from the factory to give children only introspection
builtins (no extensions). If the factory itself is `null`, children get
no extensions at all and no introspection.

### Automatic Extension Inheritance

When `childExtensionCoordinatorFactory` is `null`, children automatically
inherit extensions from `parentExtensions` that opt in via
`createChildInstance()`:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  parentExtensions: registry.extensions,  // Pass parent's extension list
)
```

Each parent extension's `createChildInstance(context:)` is called with a
`ChildSpawnContext`. Extensions that return a new instance are registered
on the child's bridge. Extensions that return `null` are excluded.

### Per-Child Filesystem Isolation

The `sandboxBaseDir` parameter enables per-child working directories:

```dart
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  sandboxBaseDir: '/data',
  parentExtensions: registry.extensions,
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

## Futures Batching (`MontyRuntime(useFutures: true)`)

By default `MontyRuntime` dispatches host functions **serially**: each
call awaits its handler before resuming Python. Set `useFutures: true`
on the constructor to flip the bridge into the futures-batching path —
host calls dispatch concurrently within a single Python execution, and
Python's `await ext()` against a Dart-registered handler returns the
resolved value instead of raising `TypeError`.

```dart
final runtime = MontyRuntime(useFutures: true)
  ..register(slowHostFn);

await runtime.execute('''
import asyncio
results = await asyncio.gather(slow(1), slow(2), slow(3))
''').result;
// All three host calls dispatch concurrently; total wall time ≈ one delay,
// not three.
```

What changes when `useFutures: true`:

1. Python calls a host function. The bridge dispatches it via
   `dispatchToolCallAsFuture` — the handler is launched as an unawaited
   `Future` and registered in `_pendingFutures`. The platform is
   resumed via `resumeAsFuture()` so Python keeps running.
2. If Python calls more host functions before suspending, those are
   also dispatched as futures, in parallel with earlier ones.
3. When Python's interpreter actually needs the concrete result of a
   host call (any `await fn()` or implicit await inside `asyncio.gather`),
   the platform emits `MontyResolveFutures` with the list of pending
   call IDs.
4. The bridge awaits each registered future, collects values into
   `results` and per-call exceptions into `errors`, then feeds the
   batch back via `(_platform as MontyFutureCapable).resolveFutures(
   results, errors: errors)`.

This is transparent to handler implementations — they're written the
same way regardless of the flag. The only difference is execution
ordering.

### When to leave the flag off (the default)

- Your handlers don't benefit from concurrency (sync values, fast pure
  computations).
- Your handlers mutate shared state and you need the legacy serial-
  dispatch guarantee. Concurrent dispatch lets handlers race against
  each other; serialising at the dispatch boundary is the simplest way
  to avoid that.
- You want bit-for-bit back-compat with pre-flag behaviour.

### When to flip it on

- Your script uses Python `await ext()` against a Dart-registered host
  function (the only way to express "this call is async" inside
  Python). Without `useFutures: true`, that line raises
  `TypeError: 'str' object can't be awaited` because the eager dispatch
  path returns a plain value.
- Your handlers do real I/O (HTTP, file, sub-process) and you want
  `asyncio.gather` to actually parallelise — sequential dispatch costs
  you the sum of all handler latencies.

### Error handling

`useFutures: true` collects per-call errors into the `errors` map and
hands them to `resolveFutures`. The pydantic-monty engine surfaces a
failed future as a script termination (`MontyScriptError`) with the
error message verbatim — Python's own `try / except RuntimeError`
around `await fn()` does **not** catch it today. If you want recovery
semantics, do the catching Dart-side inside the handler and return a
sentinel value.

For the cell-by-cell contract across every (Dart × Python × API layer
× backend) combination, see
[dart_monty_core's async-matrix deep dive][async-matrix] and the
matrix tests in `test/integration/_runtime_async_matrix_body.dart`.

[async-matrix]: https://github.com/runyaga/dart_monty_core/blob/main/docs/deep-dives/async-matrix.md
