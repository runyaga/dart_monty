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

> **Where to apply limits with `MontyRuntime`.** `MontyRuntime` does
> not accept a `limits` parameter — see [Resource Limits with
> MontyRuntime](api-reference.md#resource-limits-with-montyruntime)
> in the API reference. The mechanisms below describe the full
> constraint surface; how to wire them onto a `MontyRuntime` lives
> in api-reference.md.

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

### Security boundary — what the sandbox does NOT constrain

> **Host functions run with full host-process privileges.** The
> sandbox boundary is around the *Python interpreter*, not around
> your Dart process. Anything the host does in response to a
> host-function call — file I/O, network requests, subprocess
> execution — runs **outside** the sandbox. The Python caller can
> drive any host function you expose, so audit every one as if its
> arguments came from an attacker.

This is a security-relevant distinction worth reading carefully
before exposing host functions to user-authored Python.

| Dimension | Why it's not constrained |
|---|---|
| **Host functions you expose** | The Dart code that backs a host function runs on the host thread with full host-process privileges. If you register a host function that performs network I/O, file writes, subprocess execution, etc., the Python caller can drive that from inside the sandbox. The sandbox does not, and cannot, restrict what your own host code does. **Audit every host function you expose like you would audit user-supplied input running in your own process.** |
| **CPU usage of the host process itself** | The interpreter runs on the host thread for native backends and a Worker thread for WASM. A tight Python loop counts against `MontyLimits(timeoutMs:)` (wall-clock) but the host's overall CPU draw is unbounded. |
| **Per-call instruction count independent of wall-clock time** | There is no explicit instruction-budget mechanism — only wall-clock and memory caps. |
| **Network** | The sandbox has no built-in network constraint because the Python stdlib has no `requests`/`urllib`/`http`. **Network access only exists if you register a host function for it**, and once you do, see the host-functions row above. |
| **Filesystem (when an `OsCallHandler` is registered)** | The same applies to `OsCallHandler`. The sandbox blocks all filesystem access by default; *if* you register a handler, the handler runs with host privileges. Use `sandboxedFsHandler` or `readOnlyHandler` to keep the host code itself confined to a chosen subtree. |

See [Sandbox Architecture](../deep-dives/sandbox-architecture.md) for the
full deep dive on the parent↔child runtime topology.

### What sandbox children inherit (and what they don't)

> **`runtime.register(HostFunction(...))` does NOT propagate to
> sandbox children.** Children only see host functions provided by
> `MontyExtension` instances on the parent's `extensions: [...]`
> list — never functions registered directly on the parent's
> runtime.

If a child script calls a custom host function it expected to find
because you registered it on the parent, it fails at runtime with
`RuntimeError: Unknown function <name>`. This is by design, not a
bug — but it surprises everyone the first time.

**Why the asymmetry.** Each child interpreter is a fresh
`MontyPlatform` with its own bridge and its own host-function
registry. The parent's bridge is not the child's bridge. The
sandbox is, after all, a *sandbox* — children are isolated from
the parent's runtime state by default.

`MontyExtension` is the **formal mechanism** for declaring that a
piece of host functionality crosses the sandbox boundary. Each
extension exposes:

- `childPolicy` — declares how it propagates: `clone` (fresh
  instance per child), `reuse` (single instance shared with all
  children), or `none` (parent-only).
- `createChildInstance(ChildSpawnContext)` — the factory that
  produces the child's instance.

When a child spawns, `SandboxExtension` walks the parent's
extension list, calls each extension's `createChildInstance(...)`
per its `childPolicy`, and registers the resulting host functions
on the child's bridge. Functions registered via bare
`runtime.register(HostFunction(...))` are not in this graph — they
have no `childPolicy`, no factory, no opinion about propagation —
so the child has no way to pick them up.

**The workaround**: wrap the host function in a `MontyExtension`
subclass and register it via `extensions:`, not via
`runtime.register(...)`:

```dart
class MyHostFn extends MontyExtension {
  @override
  String get namespace => 'app';

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  MontyExtension createChildInstance(ChildSpawnContext ctx) =>
      MyHostFn();

  @override
  List<HostFunction> get functions => [
        HostFunction(
          schema: const HostFunctionSchema(
            name: 'app_query',
            description: 'Query the host application state.',
            params: [HostParam(name: 'key', type: HostParamType.string)],
          ),
          handler: (args, ctx) async {
            // ... implementation ...
            return 'value';
          },
        ),
      ];
}

// Now `app_query` is available in BOTH parent and child interpreters:
final runtime = MontyRuntime(
  extensions: [MyHostFn(), SandboxExtension(...)],
);
```

If you can't wrap into a `MontyExtension` (e.g., the function
closes over runtime state you don't want to clone), the alternative
is to compute the value in the parent and pass it into the child's
`code` argument at spawn time:

```python
# Python (running on the parent runtime)
data = app_query(key='users')   # parent has access
h = sandbox_spawn(code=f'data = {data!r}\n# ... child uses data ...')
result = sandbox_await(h)
```

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
  maxChildren: 16,       // concurrent child limit (default)
  maxDepth: 3,           // grandchild recursion limit (default)
  childLimits: MontyLimits(
    timeoutMs: 10000,
    memoryBytes: 4 * 1024 * 1024,
  ),
  childVfsStrategy: ChildVfsStrategy.isolated,  // default
)
```

> **Children inherit only built-in extension functions, not your
> custom host functions.** Children automatically gain
> `tmpl_render`, `msg_send`, `sandbox_spawn`, etc. (the host
> functions registered by built-in `MontyExtension` instances on the
> parent runtime). They do **not** inherit host functions you
> registered via `runtime.register(HostFunction(...))` — those live
> only on the parent. If a child script needs a custom host
> function, expose it through a `MontyExtension` on the parent or
> pass its result into the child's `code` parameter at spawn time.

---

## Using Extensions with MontyRuntime

```dart
final session = MontyRuntime(
  extensions: [
    JinjaTemplateExtension(),
    MessageBusExtension(),
    SandboxExtension(
      platformFactory: () async => createPlatformMonty(),
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

For higher-level extensions that ship a Python wrapper layer on top of
host functions (like a dataframe extension exposing `df_load_csv` over
low-level `df_host_load_csv` host functions), see [Shipping Python
wrapper code with an
extension](../tutorials/host-functions-intermediate.md#shipping-python-wrapper-code-with-an-extension)
in the intermediate guide. That section covers the
`pythonPreamble` + `typeCheckPrefix` convention, the consumer-side
prepend pattern, and shared-vs-sandbox-mode semantics.
