# Built-in Plugins

dart_monty ships several plugins that provide host functions to sandboxed Python code. All plugins are designed to work with `AgentSession`.

| Plugin | Functions | Description |
|--------|-----------|-------------|
| **TemplatePlugin** | `tmpl_render` | Jinja2 template rendering via [dinja](https://pub.dev/packages/dinja). |
| **MessageBusPlugin** | `msg_send`, `msg_recv`, `msg_peek`, `msg_close`, `msg_stats` | In-memory named message channels. |
| **SandboxPlugin** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters with plugin inheritance. |
| **EventLoopPlugin** | (none) | Reactive signals for execution-turn UI state. |

## EventLoopPlugin

The `EventLoopPlugin` does not expose functions to Python. Instead, it provides reactive signals to your Dart application to track the state of the execution loop.

- `channelStateSignal`: Tracks whether the interpreter is idle, executing, or waiting for input.
- `lastEmittedSignal`: Emits values sent from Python via `el_emit()` in real-time.

See [Reactive Signals](../deep-dives/signals.md) for detailed usage patterns.

## TemplatePlugin

**Class:** `DinjaTemplatePlugin`
**Namespace:** `tmpl`

Renders Jinja2 templates. Supports `{{ variables }}`, `{% for %}` loops, `{% if %}` conditionals, and filters.

### Functions

**`tmpl_render(template, context)`**

```python
# Basic variable substitution
tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})
# -> 'Hello World!'
```

---

## MessageBusPlugin

**Class:** `MessageBusPlugin`
**Namespace:** `msg`

In-memory named message channels (FIFO queues). Useful for inter-process communication between parent and child sandboxes.

### Functions

**`msg_send(name, message)`** — Send a message to a named channel.
**`msg_recv(name, timeout_ms=None)`** — Receive the next message (blocking).
**`msg_peek(name)`** — Check the next message without consuming it.

---

## SandboxPlugin

**Class:** `SandboxPlugin`
**Namespace:** `sandbox`

Spawns Python scripts in isolated child interpreters. Children can inherit plugins from the parent and even spawn their own children (grandchildren).

### Functions

**`sandbox_spawn(code, timeout_ms=None, memory_bytes=None)`** — Spawn a child. Returns an integer handle.
**`sandbox_await(handle)`** — Wait for a child to complete and return its result.
**`sandbox_gather(handles)`** — Wait for multiple children and return attributed results.

### Configuration

```dart
SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  childPluginRegistryFactory: (context) async => PluginRegistry()..register(MyPlugin()),
  maxChildren: 16,
  maxDepth: 3,
  childLimits: MontyLimits(timeoutMs: 10000),
)
```

---

## Using Plugins with `AgentSession`

`AgentSession` is the recommended way to use plugins. It orchestrates the bridge and handles the event loop automatically.

```dart
final session = AgentSession(
  plugins: [
    DinjaTemplatePlugin(),
    MessageBusPlugin(),
    SandboxPlugin(platformFactory: () async => MontyFfi()),
  ],
);

// All plugin functions are now available in Python
final result = await session.execute("tmpl_render(template='Hello {{ x }}', context={'x': 42})");
print(result.value); // 'Hello 42'

await session.dispose();
```

---

## Writing Plugins — Advanced Features

When authoring custom plugins, several advanced capabilities are available to handle cross-plugin communication, OS integration, and execution lifecycle hooks:

### Registry Injection

The `registry` field is automatically injected before `onRegister` fires. Use it to discover peer plugins:

```dart
class MyPlugin extends MontyPlugin {
  @override
  Future<void> onRegister(MontyBridge bridge) async {
    // sibling<T>() works after onRegister
    final bus = sibling<MessageBusPlugin>();
    bus?.send('init', {'plugin': namespace});
  }
}
```

### OS Contributions

Plugins can contribute to the virtual filesystem by providing an `osContribution` map.

```dart
@override
Map<String, OsProvider>? get osContribution => {
  'Path./my_plugin': MyPluginFsProvider(),
};
```

### Execute Hooks

Set `hasExecuteHooks = true` to wrap every `session.execute()` call with lifecycle hooks.

```dart
@override
bool get hasExecuteHooks => true;

@override
void onExecuteStart(String code) => print('Starting: $code');

@override
void onExecuteEnd(ExecuteOutcome outcome) => print('Finished: ${outcome.value}');
```

### System Prompt Context

Provide context that can be used by LLMs to understand how to use your plugin.

```dart
@override
String? get systemPromptContext => 'Use this plugin to manage user preferences.';
```

---

For a full list of available signals, see the [Reactive Signals](../deep-dives/signals.md) deep dive.
