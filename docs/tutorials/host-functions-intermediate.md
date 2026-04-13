# Host Functions -- Intermediate

This guide covers organizing host functions into plugins, the plugin
registry, namespace validation, lifecycle hooks, introspection builtins,
system prompt generation, and the `EventLoopPlugin`.

**Prerequisites:** Read the [Beginner guide](host-functions-beginner.md) first.

## MontyPlugin

For anything beyond a handful of functions, use `MontyPlugin` to group
related functions into a namespaced, lifecycle-managed unit.

`MontyPlugin` is an abstract class with four members:

| Member | Type | Purpose |
|--------|------|---------|
| `namespace` | `String` (abstract getter) | Unique prefix for all function names |
| `functions` | `List<HostFunction>` (abstract getter) | Host functions this plugin provides |
| `systemPromptContext` | `String?` (virtual getter) | Optional LLM prompt context; defaults to `null` |
| `onRegister(bridge)` | `Future<void>` (lifecycle hook) | Called when the plugin is attached to a bridge |
| `onDispose()` | `Future<void>` (lifecycle hook) | Called when the session ends; must be idempotent |

### Example Plugin

```dart
import 'package:dart_monty_bridge/dart_monty_bridge.dart';

class StoragePlugin extends MontyPlugin {
  final Map<String, Object?> _store = {};

  @override
  String get namespace => 'storage';

  @override
  String? get systemPromptContext =>
      'Key-value storage. Values persist for the session lifetime.';

  @override
  List<HostFunction> get functions => [
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'storage_get',
        description: 'Get a value by key. Returns null if not found.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
        ],
      ),
      handler: (args) async => _store[args['key'] as String],
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'storage_set',
        description: 'Set a key-value pair.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
          HostParam(name: 'value', type: HostParamType.any),
        ],
      ),
      handler: (args) async {
        _store[args['key'] as String] = args['value'];
        return null;
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'storage_delete',
        description: 'Delete a key. No-op if not found.',
        params: [
          HostParam(name: 'key', type: HostParamType.string),
        ],
      ),
      handler: (args) async {
        _store.remove(args['key'] as String);
        return null;
      },
    ),
    HostFunction(
      schema: const HostFunctionSchema(
        name: 'storage_keys',
        description: 'List all stored keys.',
      ),
      handler: (args) async => _store.keys.toList(),
    ),
  ];

  @override
  Future<void> onRegister(MontyBridge bridge) async {
    // Initialize resources (e.g., open a database connection)
  }

  @override
  Future<void> onDispose() async {
    _store.clear();
    // Clean up resources (e.g., close database connection)
  }
}
```

### Naming Rule

All function names **must** be prefixed with `{namespace}_`. A plugin
with namespace `storage` must name its functions `storage_get`,
`storage_set`, etc. The registry enforces this at registration time.

## PluginRegistry

`PluginRegistry` collects plugins, validates them, and wires them onto
a bridge:

```dart
final registry = PluginRegistry()
  ..register(StoragePlugin())
  ..register(MathPlugin());

final bridge = MontyBridge(platform: Monty());
await registry.attachTo(bridge);
```

### What `register()` Validates

The `register()` method performs strict validation before accepting a plugin:

- **Namespace format:** Must match `[a-z][a-z0-9_]*`, max 32 characters.
- **Reserved namespaces:** `introspection` is reserved for builtins.
- **No duplicate namespaces:** Each namespace can only be registered once.
- **Function prefix:** Every function name must start with `{namespace}_`.
- **No duplicate function names:** No function name can collide with any
  previously registered function, even across plugins.
- **No internal duplicates:** A plugin cannot declare the same function
  name twice.

Violations throw `ArgumentError` (format issues) or `StateError`
(collision/reservation issues).

### What `attachTo()` Does

`attachTo(bridge)` performs three actions:

1. Registers every plugin's `HostFunction`s onto the bridge via
   `bridge.register()`.
2. Calls `onRegister(bridge)` on each plugin in **registration order**.
3. Registers **introspection builtins** (`list_functions` and `help`)
   so Python code can discover available tools at runtime.

If any `onRegister()` call throws, the error is collected but does not
prevent other plugins from being wired. After all plugins are attached,
a single `StateError` is thrown containing all collected errors.

### Disposal

```dart
await registry.disposeAll();
```

Calls `onDispose()` on each plugin in **reverse registration order**.
Like `attachTo()`, errors are
collected and thrown as a single `StateError` after all plugins have
been disposed. Safe to call multiple times -- each plugin's
`onDispose()` must be idempotent.

### Accessing Registered Plugins

```dart
final plugins = registry.plugins; // UnmodifiableListView<MontyPlugin>
```

## Introspection Builtins

When a `PluginRegistry` is attached to a bridge, Python automatically
gets two functions for runtime tool discovery:

### `list_functions()`

Returns JSON listing all available functions grouped by namespace:

```python
import json
tools = json.loads(list_functions())
# {
#   "tools": {
#     "storage": [
#       {"name": "storage_get", "description": "...", "params": [...]},
#       {"name": "storage_set", "description": "...", "params": [...]}
#     ],
#     "math": [...],
#     "introspection": [
#       {"name": "list_functions", "description": "...", "params": []},
#       {"name": "help", "description": "...", "params": [...]}
#     ]
#   }
# }
```

The introspection category always includes itself (both `list_functions`
and `help`).

### `help(name)`

Returns JSON detail for a single function. Accepts both fully-qualified
names and bare names (without the namespace prefix):

```python
import json

# Fully-qualified name -- exact match
info = json.loads(help("storage_get"))
# {"name": "storage_get", "description": "Get a value by key...",
#  "params": [{"name": "key", "type": "string", "required": true}]}

# Bare name -- resolves when unambiguous
info = json.loads(help("get"))
# Same result if only one plugin has a function ending in "_get"
```

When a bare name matches multiple functions across different namespaces,
`help()` returns a disambiguation list:

```python
info = json.loads(help("create"))
# {"error": "ambiguous",
#  "message": "Multiple functions match \"create\". Use the fully-qualified name.",
#  "candidates": ["df_create", "form_create", "storage_create"]}
```

If the function name is unknown (neither exact nor bare match), returns
the string `"Unknown function: <name>"`.

These builtins enable LLM-generated Python to discover and use tools
dynamically without hardcoded knowledge of the available API.

## System Prompt Generation

`PluginRegistry` can auto-generate an LLM system prompt from all
registered plugin schemas:

```dart
final prompt = registry.generateSystemPrompt();
```

The output is structured markdown:

```text
### storage
Key-value storage. Values persist for the session lifetime.
- `storage_get(key: string)`: Get a value by key. Returns null if not found.
- `storage_set(key: string, value: any)`: Set a key-value pair.
- `storage_delete(key: string)`: Delete a key. No-op if not found.
- `storage_keys()`: List all stored keys.

### math
- `math_sqrt(n: number)`: Compute square root.
```

Each plugin becomes a markdown section with:
- The namespace as an `###` heading.
- The `systemPromptContext` string (if non-null and non-empty).
- A bullet list of functions with parameters (optional params suffixed
  with `?`) and descriptions.

### System Prompt Prefix

`PluginRegistry` has a `systemPromptPrefix` field that prepends text
before all plugin sections in the generated prompt. This is set at
**runtime** -- typically by `SandboxPlugin._handleSpawn` when
spawning child sandboxes:

```dart
// SandboxPlugin sets this automatically at spawn time:
registry.systemPromptPrefix =
    'You are child 3. Your workspace is /data/.sandboxes/child_3.';

final prompt = registry.generateSystemPrompt();
// Output:
// You are child 3. Your workspace is /data/.sandboxes/child_3.
//
// ### storage
// Key-value storage. Values persist for the session lifetime.
// - `storage_get(key: string)`: ...
```

You do not set this manually -- `SandboxPlugin` computes and injects
it after registry construction using the `systemPromptBuilder` callback
and the `system_prompt` argument from `sandbox_spawn`. See the
[Advanced guide](host-functions-advanced.md) for details on the
dual-layer injection system.

## EventLoopPlugin

`EventLoopPlugin` is a `MontyPlugin` that turns a single `execute` call
into a long-running cooperative exchange between Python and Dart. Register
it like any other plugin through `PluginRegistry`:

| Function | Purpose |
|----------|---------|
| `el_recv()` | Pauses Python until a value is dispatched from Dart |
| `el_emit(value)` | Emits a map value from Python to the host |

### The Pattern

Python holds state in a loop, calling `el_recv()` to pause and
`el_emit(value)` to push values back to the host:

```python
state = {"count": 0}

while True:
    el_emit({"type": "counter", "count": state["count"]})
    event = el_recv()

    if event["action"] == "increment":
        state["count"] = state["count"] + 1
    elif event["action"] == "reset":
        state["count"] = 0
    elif event["action"] == "quit":
        break
```

### Dart Side

```dart
final plugin = EventLoopPlugin();
final registry = PluginRegistry()..register(plugin);
final bridge = DefaultMontyBridge(platform: Monty());
await registry.attachTo(bridge);

// Observe emitted values
plugin.lastEmittedSignal.subscribe((value) {
  if (value != null) print('Python emitted: $value');
});

// Start the Python event loop
final events = bridge.execute(pythonCode);
events.listen((event) { /* handle lifecycle events */ });

// Dispatch values to Python
plugin.dispatch({'action': 'increment'});
plugin.dispatch({'action': 'increment'});
plugin.dispatch({'action': 'quit'});
```

### Channel State

The plugin exposes lifecycle state as a reactive signal:

| State | Meaning |
|-------|---------|
| `BridgeChannelIdle` | Plugin created, no script executing |
| `BridgeChannelExecuting` | Python is actively running |
| `BridgeChannelWaiting` | Python is paused at `el_recv()` |
| `BridgeChannelCompleted` | Script finished (normally or with error) |
| `BridgeChannelDisposed` | Plugin has been disposed |

Read with `plugin.channelState` (non-reactive) or subscribe via
`plugin.channelStateSignal` with the signals API:

```dart
effect(() {
  if (plugin.channelStateSignal.value is BridgeChannelWaiting) {
    showInputField();
  }
});
```

### Event Queuing

If you call `dispatch()` while Python is not yet at `el_recv()`, the
value is queued and delivered the next time Python calls `el_recv()` —
no timing coordination required. Values dispatched before `execute()` is
called are also queued and delivered on the first `el_recv()`.

### Disposal

`plugin.onDispose()` completes any pending `el_recv()` completer with a
`StateError`, clears the event queue, and disposes the signals. The
method is idempotent — safe to call multiple times.

## Next Steps

The [Advanced guide](host-functions-advanced.md) covers `SandboxPlugin`
for spawning child interpreters, depth and concurrency limits, resource
limits per child, and production patterns for multi-session
architectures.
