# Built-in Extensions

dart_monty ships three extensions that provide host functions to
sandboxed Python code. All extensions work with `MontyRuntime`.

| Extension | Functions | Description |
|--------|-----------|-------------|
| **JinjaTemplateExtension** | `tmpl_render` | Jinja2 template rendering |
| **MessageBusExtension** | `msg_send`, `msg_recv`, `msg_peek`, `msg_close`, `msg_stats` | In-memory named channels |
| **SandboxExtension** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters |

## JinjaTemplateExtension

**Class:** `JinjaTemplateExtension`
**Namespace:** `tmpl`

Renders Jinja2 templates using the [jinja](https://pub.dev/packages/jinja)
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
```

### Configuration

```dart
JinjaTemplateExtension()
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

---

## SandboxExtension

**Class:** `SandboxExtension`
**Namespace:** `sandbox`

Spawns Python scripts in isolated child interpreters. Each child
gets its own `MontyPlatform` and `PlatformBridge`. Children
can inherit extensions from the parent and even spawn their own
children (grandchildren).

### Sandbox Functions

**`sandbox_spawn(code, timeout_ms=None, memory_bytes=None)`** —
Spawn a child interpreter. Returns an integer handle.

```python
h = sandbox_spawn(code='sum(range(100))')
```

**`sandbox_await(handle)`** — Wait for a child to complete.
Returns the result value.

```python
result = sandbox_await(h)  // -> 4950
```

### Sandbox Configuration

```dart
SandboxExtension(
  platformFactory: () async => MontyFfi(),  // or MontyWasm()
  childVfsStrategy: ChildVfsStrategy.isolated,
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
      platformFactory: () async => MontyFfi(),
    ),
  ],
);

// All extension functions are now available in Python
final handle = session.execute("tmpl_render(template='{{ x }}', context={'x': 1})");
final result = await handle.result;
print(result.value); // 1

await session.dispose();
```

## Writing Custom Extensions

See the [host functions guide](../tutorials/host-functions-intro.md) for
how to create your own extensions with custom host functions.
