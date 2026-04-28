# Built-in Extensions

dart_monty ships three extensions that provide host functions to
sandboxed Python code. All extensions work with `MontyRuntime`.

| Extension | Functions | Description |
|--------|-----------|-------------|
| **TemplateExtension** | `tmpl_render` | Jinja2 template rendering |
| **MessageBusExtension** | `msg_send`, `msg_recv`, `msg_peek`, `msg_close`, `msg_stats` | In-memory named channels |
| **SandboxExtension** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters |

## TemplateExtension

**Class:** `JinjaTemplateExtension`
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
JinjaTemplateExtension(
  maxInputSize: 512 * 1024,  // 512 KB default
)
```

---

## MessageBusExtension

**Class:** `MessageBusExtension`
**Namespace:** `msg`

In-memory named message channels (FIFO queues). Useful for
inter-process communication when combining multiple extensions
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

## SandboxExtension

**Class:** `SandboxExtension`
**Namespace:** `sandbox`

Spawns Python scripts in isolated child interpreters. Each child
gets its own `MontyPlatform` and `DefaultMontyBridge`. Children
can inherit extensions from the parent and even spawn their own
children (grandchildren).

### What the sandbox actually constrains

| Dimension | Mechanism | Limit / behaviour |
|---|---|---|
| **Memory** | `MontyLimits(memoryBytes:)` on parent or per-child | Hard cap; raises `MontyResourceError.MemoryLimitExceeded` on overflow |
| **CPU / wall-clock** | `MontyLimits(timeoutMs:)` | Raises `MontyResourceError.TimeoutError` on overflow |
| **Stack depth** | `MontyLimits(stackDepth:)` | Raises a Python `RecursionError` on overflow |
| **Filesystem** | `OsCallHandler` composition (`memoryFsHandler`, `sandboxedFsHandler`, `readOnlyHandler`, `overlayFsHandler`) | No filesystem access at all unless an `OsCallHandler` is registered for `Path.*` |
| **Network** | None native — Python stdlib has no `requests`/`urllib`/`http` | Network access is exposed only via host functions you register |
| **Child concurrency** | `maxChildren:` on `SandboxExtension` | Hard cap on simultaneous live children |
| **Child depth** | `maxDepth:` on `SandboxExtension` | Cap on grandchild → great-grandchild recursion |
| **Per-child VFS** | `childVfsStrategy:` (`isolated` default, `shared`, `none`) | Whether children inherit the parent's VFS or get their own |

**Not constrained**: per-call instruction count independent of
wall-clock time (the interpreter runs on the host thread for native
backends and a Worker thread for WASM); CPU usage by the host
process itself; non-Python work the host does in handlers you
expose (those run on the host with full host privileges).

See [Sandbox Architecture](../deep-dives/sandbox-architecture.md) for the
full deep dive on the parent↔child runtime topology.

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
SandboxExtension(
  platformFactory: () async => createPlatformMonty(),
  parentExtensions: [tmpl, msgBus],  // children inherit these
  maxChildren: 16,       // concurrent child limit
  maxDepth: 3,           // grandchild recursion limit
  childLimits: MontyLimits(
    timeoutMs: 10000,
    memoryBytes: 4 * 1024 * 1024,
  ),
)
```

---

## Using Extensions with MontyRuntime

```dart
final session = MontyRuntime(
  extensions: [
    JinjaTemplateExtension(),
    MessageBusExtension(),
    SandboxExtension(
      platformFactory: () async => createPlatformMonty(),
      parentExtensions: [JinjaTemplateExtension()],
    ),
  ],
);

// All extension functions are now available in Python
await session.execute("help()").result;  // lists all functions
await session.execute("tmpl_render(template='{{ x }}', context={'x': 1})").result;
await session.execute("msg_send('ch', 'hello')").result;
await session.execute("h = sandbox_spawn(code='42')").result;

await session.dispose();
```

## Writing Custom Extensions

See the [host functions guide](../tutorials/host-functions-intro.md) for
how to create your own extensions with custom host functions.
