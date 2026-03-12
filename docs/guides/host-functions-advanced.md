# Host Functions -- Advanced

This guide covers composite plugins for inter-plugin dependencies,
the `IsolatePlugin` for spawning child Python interpreters, depth and
concurrency limits, resource limits per child, handle lifecycle
management, and production patterns.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md) first.

## Composite Plugins

Plugins are normally isolated -- they can't call each other. The
`CompositePlugin` mixin changes this by letting a plugin declare typed
dependencies on sibling plugins in the same registry.

### Why?

Without composition, an LLM must orchestrate multi-tool workflows:
"call `storage_set`, then call `budget_update`". With a composite
plugin, the LLM sees a single `budget_set(category, amount)` tool.
The delegation to `StoragePlugin` happens in Dart, invisibly.

### PluginRef and CompositePlugin

```dart
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

class BudgetPlugin extends MontyPlugin with CompositePlugin {
  // Typed, lazy reference to a sibling plugin.
  final storageRef = PluginRef<StoragePlugin>();

  @override
  String get namespace => 'budget';

  // Declare dependencies. The registry resolves these during attachTo().
  @override
  List<PluginRef<MontyPlugin>> get dependencies => [storageRef];

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'budget_set',
        description: 'Set a budget category with amount.',
        params: [
          HostParam(name: 'category', type: HostParamType.string),
          HostParam(name: 'amount', type: HostParamType.number),
        ],
      ),
      handler: (args) async {
        final category = args['category']! as String;
        final amount = args['amount']! as num;
        // Delegate to StoragePlugin's Dart API directly.
        final storage = storageRef.plugin;
        await storage.set('budget_$category', amount);
        return 'Budget set: $category = $amount';
      },
    ),
  ];
}
```

Register both plugins -- order doesn't matter:

```dart
final registry = PluginRegistry()
  ..register(BudgetPlugin())
  ..register(StoragePlugin());

await registry.attachTo(bridge);
```

### How Resolution Works

During `attachTo()`, the registry:

1. Wires all plugin functions onto the bridge.
2. Resolves `PluginRef`s using **polymorphic matching** (`is T`).
   A `PluginRef<StoragePlugin>` matches `StoragePlugin` and any subclass.
3. Calls `onRegister()` in **topological order** -- dependencies first.

If multiple registered plugins satisfy a `PluginRef<T>`, the first match
(by registration order) wins.

### Optional Dependencies

Use `required: false` for dependencies the plugin can work without:

```dart
final analyticsRef = PluginRef<AnalyticsPlugin>(required: false);

// In your handler:
if (analyticsRef.isResolved) {
  analyticsRef.plugin.track('budget_set', category);
}
```

An unresolved optional ref's `isResolved` returns `false`. Calling
`.plugin` on an unresolved ref throws `StateError`.

### Lifecycle Order

The registry topologically sorts plugins before calling lifecycle hooks:

- **`onRegister()`**: Dependencies init first, then dependents.
- **`onDispose()`**: Reverse topological order -- dependents dispose
  before their dependencies.

This means a composite plugin can safely use its dependencies in both
`onRegister()` and `onDispose()`.

### Error Handling

| Condition | Behavior |
|-----------|----------|
| Required dependency not registered | `StateError` during `attachTo()` |
| Circular dependency (A -> B -> A) | `StateError` during `attachTo()` |
| Optional dependency not registered | Ref stays unresolved; plugin adapts |

### Multi-Level Composition

Dependencies can be transitive. If `C` depends on `B` and `B` depends
on `A`, the registry resolves the full chain and initializes `A -> B -> C`:

```dart
class LayerC extends MontyPlugin with CompositePlugin {
  final bRef = PluginRef<LayerB>();

  @override
  List<PluginRef<MontyPlugin>> get dependencies => [bRef];

  // Transitive access: bRef.plugin.aRef.plugin
}
```

## IsolatePlugin

`IsolatePlugin` is a `MontyPlugin` that lets parent Python code spawn
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

### Creating an IsolatePlugin

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

final plugin = IsolatePlugin(
  platformFactory: () async => Monty(),
  maxChildren: 16,      // Max concurrent children (default: 16)
  maxDepth: 3,          // Max recursion depth (default: 3)
  currentDepth: 0,      // This plugin's depth level (default: 0)
  childLimits: MontyLimits(
    timeoutMs: 5000,
    memoryBytes: 10 * 1024 * 1024,
  ),
);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `platformFactory` | `Future<MontyPlatform> Function()` | required | Creates a fresh platform for each child |
| `childPluginRegistryFactory` | `Future<PluginRegistry?> Function()?` | `null` | Optional: provides plugins to children |
| `maxChildren` | `int` | `16` | Maximum concurrent living children |
| `maxDepth` | `int` | `3` | Maximum recursion depth for nested IsolatePlugins |
| `currentDepth` | `int` | `0` | This plugin's current depth in the recursion tree |
| `childLimits` | `MontyLimits?` | `null` | Default resource limits for all children |

### Host Functions Provided

The plugin registers these functions under the `isolate` namespace:

| Function | Description | Parameters |
|----------|-------------|------------|
| `isolate_spawn(code, timeout_ms?, memory_bytes?)` | Spawn a child. Returns an integer handle. | `code`: string (required), `timeout_ms`: integer, `memory_bytes`: integer |
| `isolate_await(handle)` | Wait for a child to complete. Returns its result. | `handle`: integer |
| `isolate_await_all(handles)` | Wait for multiple children. Returns list of results. | `handles`: list |
| `isolate_is_alive(handle)` | Check if a child is still running. Returns boolean. | `handle`: integer |
| `isolate_cancel(handle)` | Cancel a running child. No-op if already finished. | `handle`: integer |
| `isolate_free(handle)` | Release a completed child's handle. | `handle`: integer |
| `isolate_get_output(handle)` | Get a completed child's print output. | `handle`: integer |

### Basic Usage from Python

```python
# Spawn two children
h1 = isolate_spawn("2 ** 10")
h2 = isolate_spawn("3 ** 7")

# Wait for both
results = isolate_await_all([h1, h2])
# results == [1024, 2187]

# Clean up
isolate_free(h1)
isolate_free(h2)
```

### Handle Lifecycle

Each `isolate_spawn()` returns an integer handle. Handles follow a
strict lifecycle:

```text
spawn  ->  alive  ->  completed  ->  freed
                 \-> cancelled  ->  freed
```

**Rules:**

- `isolate_await(handle)` blocks until the child completes or fails.
  If the child failed, it raises an error with the child's error message.
- `isolate_free(handle)` releases the handle's resources. It throws
  `StateError` if the child is still alive -- you must await or cancel
  first.
- `isolate_get_output(handle)` returns the child's captured `print()`
  output as a string (or `null` if no output). Throws `StateError` if
  the child is still running.
- `isolate_cancel(handle)` stops a running child. No-op if already
  finished. The child's completer receives a `StateError`. Do not
  cancel an already-freed handle -- it throws `ArgumentError`.
- `isolate_is_alive(handle)` returns `true` if the child is still
  executing.
- Unknown handles throw `ArgumentError`.

**Warning:** You must call `isolate_free()` on every completed or
cancelled handle. Handles are never garbage collected automatically.
Failing to free handles causes a silent memory leak (the `_ChildHandle`
and its captured output remain in memory) and will eventually exhaust
`maxChildren`, preventing new children from being spawned.

### Per-Child Resource Limits

Children can override the default `childLimits` at spawn time:

```python
# Use default limits from childLimits
h1 = isolate_spawn("expensive_computation()")

# Override timeout for this specific child
h2 = isolate_spawn("slow_task()", timeout_ms=30000)

# Override memory for this specific child
h3 = isolate_spawn("memory_heavy()", memory_bytes=50000000)

# Override both
h4 = isolate_spawn("big_slow()", timeout_ms=60000, memory_bytes=100000000)
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

If children also have `IsolatePlugin` registered (via
`childPluginRegistryFactory`), they can spawn their own children. The
`maxDepth` and `currentDepth` parameters control how deep this
recursion can go:

```dart
IsolatePlugin(
  platformFactory: () async => Monty(),
  maxDepth: 3,
  currentDepth: 0,
  childPluginRegistryFactory: () async {
    final registry = PluginRegistry();
    registry.register(IsolatePlugin(
      platformFactory: () async => Monty(),
      maxDepth: 3,
      currentDepth: 1,  // One level deeper
    ));
    return registry;
  },
)
```

When `currentDepth >= maxDepth`, `isolate_spawn()` throws `StateError`
with the message `"Maximum isolate recursion depth (N) exceeded."`.

### Concurrency Limits

`maxChildren` limits the number of **alive** children at any time.
When the limit is reached, `isolate_spawn()` throws `StateError` with
the message `"Maximum concurrent children (N) reached."`.

Freed children do not count against the limit. After
`isolate_free(handle)`, the slot is available for new children.

Cancelled children are marked as not alive and also do not count.

## Providing Plugins to Children

By default, children only get the introspection builtins (if a
`PluginRegistry` is attached). Use `childPluginRegistryFactory` to
give children access to host functions:

```dart
IsolatePlugin(
  platformFactory: () async => Monty(),
  childPluginRegistryFactory: () async {
    final registry = PluginRegistry();
    registry.register(MathPlugin());
    registry.register(StoragePlugin());
    // Note: do NOT register IsolatePlugin here unless you want
    // recursive spawning (and remember to increment currentDepth)
    return registry;
  },
)
```

Return `null` from the factory to give children only introspection
builtins (no plugins). If the factory itself is `null`, children get
no plugins at all and no introspection.

## Disposal and Cleanup

When `IsolatePlugin.onDispose()` is called:

1. All living children are cancelled.
2. Each cancelled child's completer is completed with a `StateError`.
3. Unhandled async errors from cancelled children are suppressed (via
   `future.ignore()`).
4. The children map is cleared.

Disposal is idempotent -- calling `onDispose()` multiple times is safe.

When a child completes (normally or with error), the plugin performs
best-effort cleanup: the child's bridge is disposed, its platform is
disposed, and its plugin registry (if any) is disposed. Cleanup errors
are swallowed to avoid masking the child's actual result.

## Production Patterns

### Fan-Out / Fan-In

```python
# Fan out work
handles = []
items = ["task_a", "task_b", "task_c", "task_d"]
i = 0
while i < len(items):
    h = isolate_spawn('process("' + items[i] + '")')
    handles.append(h)
    i = i + 1

# Fan in results
results = isolate_await_all(handles)

# Clean up all handles
i = 0
while i < len(handles):
    isolate_free(handles[i])
    i = i + 1
```

### Timeout with Fallback

```python
h = isolate_spawn("slow_computation()", timeout_ms=5000)
try:
    result = isolate_await(h)
except:
    # Child timed out or failed
    result = "fallback_value"
isolate_free(h)
```

### Checking Progress

```python
h = isolate_spawn("long_running_task()")

# Poll periodically (in practice, do useful work between checks)
while isolate_is_alive(h):
    # ... do other work ...
    pass

result = isolate_await(h)
output = isolate_get_output(h)
isolate_free(h)
```

### Graceful Cancellation

```python
handles = []
i = 0
while i < 10:
    handles.append(isolate_spawn("work_unit(" + str(i) + ")"))
    i = i + 1

# Cancel all remaining after getting first result
first = isolate_await(handles[0])
i = 1
while i < len(handles):
    isolate_cancel(handles[i])
    i = i + 1

# Free all
i = 0
while i < len(handles):
    isolate_free(handles[i])
    i = i + 1
```

## Writing Custom Plugins for Production

### Plugin Design Checklist

1. **Namespace:** Choose a short, descriptive namespace (e.g., `db`,
   `http`, `auth`). It must match `[a-z][a-z0-9_]*` and be at most
   32 characters.

2. **Function naming:** All function names must start with
   `{namespace}_`. Keep names descriptive but concise:
   `db_query`, `db_execute`, `db_tables`.

3. **System prompt context:** Provide `systemPromptContext` if your
   plugin needs explanation beyond what the function schemas convey.
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

7. **Thread safety:** If your plugin holds mutable state, consider
   that `DefaultMontyBridge` processes one execution at a time (it
   throws `StateError` on concurrent `execute()` calls), but futures
   batching means multiple handlers can run concurrently within a
   single execution.

### Multi-Session Patterns

When running multiple bridge sessions (e.g., one per user), each
session needs its own instances:

```dart
Future<(DefaultMontyBridge, PluginRegistry)> createSession() async {
  final registry = PluginRegistry()
    ..register(StoragePlugin())  // Fresh instance per session
    ..register(MathPlugin());

  final bridge = DefaultMontyBridge(platform: Monty());
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

Each plugin instance maintains its own state. Two `StoragePlugin`
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
