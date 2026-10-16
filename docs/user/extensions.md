# Built-in Extensions

dart_monty ships extensions that provide host functions to
sandboxed Python code. All extensions work with `MontyRuntime`.

| Extension | Functions | Description |
|--------|-----------|-------------|
| **SandboxExtension** | `sandbox_spawn`, `sandbox_await`, `sandbox_gather`, `sandbox_free` | Isolated child interpreters |

## SandboxExtension

**Class:** `SandboxExtension`
**Namespace:** `sandbox`

Spawns Python scripts in isolated child interpreters. Each child
gets its own session and bridge. Children
can inherit extensions from the parent and even spawn their own
children (grandchildren).

See [Sandbox Architecture](../deep-dives/sandbox-architecture.md) for the
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

### Browser memory

A browser child is a Web Worker with its own workspace. Keep `files` and
`ro_files` copy-in to about 1 MiB per child so that the memory 16 children add
to a page stays within 320 MB. See
[Browser memory](../deep-dives/sandbox-architecture.md#browser-memory) for the
measurements.

### Sandbox Configuration

```dart
SandboxExtension(
  maxChildren: 16,       // concurrent child limit
  maxDepth: 3,           // grandchild recursion limit
  childLimits: const ResourceLimits(
    maxFeedDuration: Duration(seconds: 10),
    maxMemory: 4 * 1024 * 1024,
  ),
)
```

---

## Using Extensions with MontyRuntime

```dart
final session = await MontyRuntime.start(
  extensions: [
    SandboxExtension(),
  ],
);

// All extension functions are now available in Python
await session.execute("help()").result;  // lists all functions
await session.execute("h = sandbox_spawn(code='42')").result;

await session.dispose();
```

## Writing Custom Extensions

See the [host functions guide](../tutorials/host-functions-intro.md) for
how to create your own extensions with custom host functions.
