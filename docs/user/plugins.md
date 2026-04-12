# Built-in Plugins

dart_monty ships three plugins that provide host functions to
sandboxed Python code. All plugins work with `ReplSession`.

| Plugin | Functions | Description |
|--------|-----------|-------------|
| **TemplatePlugin** | `tmpl_render` | Jinja2 template rendering |
| **MessageBusPlugin** | `msg_send`, `msg_recv`, `msg_peek`, `msg_close`, `msg_stats` | In-memory named channels |
| **SandboxPlugin** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters |

## TemplatePlugin

**Class:** `DinjaTemplatePlugin`
**Namespace:** `tmpl`

Renders Jinja2 templates using the [dinja](https://pub.dev/packages/dinja)
Dart package. Supports `{{ variables }}`, `{% for %}` loops,
`{% if %}` conditionals, and filters.

### Functions

**`tmpl_render(template, context)`**

Render a Jinja2 template string with a context dict.

```python
# Basic variable substitution
tmpl_render(template='Hello {{ name }}!', context={'name': 'World'})
# -> 'Hello World!'

# For loop
tmpl_render(
    template='{% for item in items %}{{ item }} {% endfor %}',
    context={'items': ['Alice', 'Bob', 'Charlie']}
)
# -> 'Alice Bob Charlie '

# Conditional
tmpl_render(
    template='{% if admin %}Admin{% else %}Guest{% endif %}',
    context={'admin': True}
)
# -> 'Admin'
```

### Typical Pattern

Compute data in Python, render with the host template engine:

```python
scores = [85, 92, 78, 95, 88]
report = {
    'avg': sum(scores) / len(scores),
    'top': max(scores),
    'n': len(scores),
}
tmpl_render(
    template='{{ n }} students, avg={{ avg }}, top={{ top }}',
    context=report,
)
# -> '5 students, avg=87.6, top=95'
```

### Configuration

```dart
DinjaTemplatePlugin(
  maxInputSize: 512 * 1024,  // 512 KB default
)
```

---

## MessageBusPlugin

**Class:** `MessageBusPlugin`
**Namespace:** `msg`

In-memory named message channels (FIFO queues). Useful for
inter-process communication when combining multiple plugins
or coordinating between parent and child sandboxes.

### MessageBus Functions

**`msg_send(name, message)`** — Send a message to a named channel.

```python
msg_send('tasks', {'id': 1, 'action': 'analyze'})
```

**`msg_recv(name, timeout_ms=None)`** — Receive the next message.
Blocks until a message is available or timeout expires.

```python
task = msg_recv('tasks')
# -> {'id': 1, 'action': 'analyze'}
```

**`msg_peek(name)`** — Check the next message without consuming it.
Returns `None` if the channel is empty.

```python
msg_peek('tasks')  # -> {'id': 1, ...} or None
```

**`msg_close(name)`** — Close a channel. Subsequent `msg_recv`
calls raise an error.

```python
msg_close('tasks')
```

**`msg_stats(name)`** — Get channel statistics.

```python
msg_stats('tasks')
# -> {'pending': 2, 'delivered': 5, ...}
```

### MessageBus Pattern

Log events from multiple operations:

```python
msg_send('audit', {'action': 'upload', 'file': 'data.csv'})
msg_send('audit', {'action': 'query', 'room': 'analysis'})

# Later: collect all audit entries
logs = []
while msg_peek('audit') is not None:
    logs.append(msg_recv('audit'))
```

---

## SandboxPlugin

**Class:** `SandboxPlugin`
**Namespace:** `sandbox`

Spawns Python scripts in isolated child interpreters. Each child
gets its own `MontyPlatform` and `DefaultMontyBridge`. Children
can inherit plugins from the parent and even spawn their own
children (grandchildren).

See [Sandbox Architecture](../architecture/sandbox-architecture.md) for the
full deep dive.

### Sandbox Functions

**`sandbox_spawn(code, timeout_ms=None, memory_bytes=None)`** —
Spawn a child interpreter. Returns an integer handle.

```python
h = sandbox_spawn(code='sum(range(100))')
```

**`sandbox_await(handle)`** — Wait for a child to complete.
Returns the result value.

```python
result = sandbox_await(h)  # -> 4950
```

**`sandbox_await_all(handles)`** — Wait for multiple children.

```python
results = sandbox_await_all(handles=[h1, h2, h3])
```

**`sandbox_gather(handles)`** — Wait and return attributed results
with handle, value, and output for each child.

```python
results = sandbox_gather(handles=[h1, h2, h3])
# [{'handle': 0, 'value': 10, 'output': None}, ...]
```

**`sandbox_is_alive(handle)`** — Check if a child is still running.

**`sandbox_free(handle)`** — Release a completed child's resources.

**`sandbox_get_output(handle)`** — Get a completed child's
captured `print()` output.

### Sandbox Pattern

Parallel computation with result aggregation:

```python
# Spawn 3 independent computations
h1 = sandbox_spawn(code='2 ** 16')
h2 = sandbox_spawn(code='sum(range(1000))')
h3 = sandbox_spawn(code='len([x for x in range(100) if x % 7 == 0])')

# Wait for all and get attributed results
results = sandbox_gather(handles=[h1, h2, h3])
for r in results:
    print(f"Handle {r['handle']}: {r['value']}")
```

### Sandbox Configuration

```dart
SandboxPlugin(
  platformFactory: () async => MontyFfi(),  // or MontyWasm()
  parentPlugins: [tmpl, msgBus],  // children inherit these
  maxChildren: 16,       // concurrent child limit
  maxDepth: 3,           // grandchild recursion limit
  childLimits: MontyLimits(
    timeoutMs: 10000,
    memoryBytes: 4 * 1024 * 1024,
  ),
)
```

---

## Using Plugins with ReplSession

```dart
final session = ReplSession(
  plugins: [
    DinjaTemplatePlugin(),
    MessageBusPlugin(),
    SandboxPlugin(
      platformFactory: () async => MontyFfi(),
      parentPlugins: [DinjaTemplatePlugin()],
    ),
  ],
);

// All plugin functions are now available in Python
await session.run("help()");  // lists all functions
await session.run("tmpl_render(template='{{ x }}', context={'x': 1})");
await session.run("msg_send('ch', 'hello')");
await session.run("h = sandbox_spawn(code='42')");

await session.dispose();
```

## Writing Custom Plugins

See the [host functions guide](../tutorials/host-functions-intro.md) for
how to create your own plugins with custom host functions.
