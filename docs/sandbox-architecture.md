# Sandbox Architecture

## Overview

`SandboxPlugin` spawns Python scripts in isolated child interpreters.
Each child gets its own `MontyPlatform`, `DefaultMontyBridge`, and
optional plugin registry. The parent Python script controls children
via host functions.

## Host Functions

| Function | Description |
|----------|-------------|
| `sandbox_spawn(code, timeout_ms?, memory_bytes?, system_prompt?)` | Spawn child interpreter, returns integer handle |
| `sandbox_await(handle)` | Wait for child to complete, returns result |
| `sandbox_await_all(handles)` | Wait for multiple children |
| `sandbox_gather(handles)` | Wait + return attributed results `[{handle, value, output}]` |
| `sandbox_is_alive(handle)` | Check if child is still running |
| `sandbox_free(handle)` | Release completed child resources |
| `sandbox_get_output(handle)` | Get child's captured `print()` output |

## Usage

```python
# Spawn a child that computes something
h = sandbox_spawn(code='sum(range(100))')

# Wait for the result
result = sandbox_await(h)  # 4950

# Parallel execution
h1 = sandbox_spawn(code='2 ** 16')
h2 = sandbox_spawn(code='3 ** 10')
results = sandbox_gather(handles=[h1, h2])
# [{'handle': 0, 'value': 65536, 'output': None},
#  {'handle': 1, 'value': 59049, 'output': None}]

# Get print output from child
h3 = sandbox_spawn(code='for i in range(5):\n    print(i)')
sandbox_await(h3)
output = sandbox_get_output(h3)  # '0\n1\n2\n3\n4\n'

# Resource limits
h4 = sandbox_spawn(
    code='while True: pass',
    timeout_ms=5000,
    memory_bytes=1048576,
)

# Clean up
sandbox_free(h1)
sandbox_free(h2)
```

## Isolation Model

Each child gets:

- **Own `MontyPlatform`** — fresh interpreter instance via `platformFactory`
- **Own `DefaultMontyBridge`** — independent dispatch loop, middleware, events
- **Own plugin registry** — inherited from parent or custom via factory
- **Own VFS** (optional) — isolated `MemoryFsProvider` per child
- **Shared time/env** — `TimeOsProvider` and `EnvOsProvider` from parent

Children cannot access the parent's heap, globals, or variables.
Communication happens only through return values and print output.

## Plugin Inheritance

When `SandboxPlugin` spawns a child, it can give the child its own
plugins. There are two modes:

### Automatic Inheritance (default)

Set `parentPlugins` on the `SandboxPlugin`. Each plugin's
`createChildInstance()` is called to create a fresh copy for the child.

```dart
final tmpl = DinjaTemplatePlugin();
final msgBus = MessageBusPlugin();
final sandbox = SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  parentPlugins: [tmpl, msgBus],  // children inherit these
);
```

Rules:
- `SandboxPlugin` itself is **skipped** during inheritance (prevents
  accidental infinite recursion)
- Plugins return `null` from `createChildInstance()` to opt out
- Plugins must return a **new instance**, not `this`

### Custom Registry Factory

For full control (including grandchild support), use
`childPluginRegistryFactory`:

```dart
final sandbox = SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  childPluginRegistryFactory: (context) async {
    final reg = PluginRegistry()
      ..register(DinjaTemplatePlugin())
      ..register(SandboxPlugin(  // child can also spawn!
        platformFactory: () async => MontyFfi(),
        currentDepth: context.childId + 1,  // increment depth
        maxDepth: 3,
      ));
    return reg;
  },
);
```

## Grandchildren

Children can spawn their own children (grandchildren) if they have
`SandboxPlugin` in their registry. This requires:

1. A `childPluginRegistryFactory` that includes a `SandboxPlugin`
   with incremented `currentDepth`
2. `maxDepth` controls the maximum recursion level (default: 3)

```python
# Parent spawns child, child spawns grandchild
child_code = """
gh = sandbox_spawn(code="6 * 7")
sandbox_await(gh)
"""
h = sandbox_spawn(code=child_code)
result = sandbox_await(h)  # 42 — computed by grandchild
```

Depth limiting prevents infinite recursion:
- `currentDepth=0` (parent) can spawn children
- `currentDepth=1` (child) can spawn grandchildren
- `currentDepth=2` (grandchild) can spawn great-grandchildren
- `currentDepth >= maxDepth` → spawn raises `StateError`

## Resource Limits

Per-child limits via `sandbox_spawn` arguments or plugin-level defaults:

```dart
SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  childLimits: MontyLimits(
    timeoutMs: 10000,    // 10 second default
    memoryBytes: 4194304, // 4MB default
  ),
);
```

Python can override per-spawn:
```python
sandbox_spawn(code='...', timeout_ms=5000, memory_bytes=1048576)
```

## System Prompts

Children can receive context via system prompts:

```dart
SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  systemPromptBuilder: (context) =>
    'You are child #${context.childId}. '
    'Working directory: ${context.workingDirectory}',
);
```

Python can add runtime prompts:
```python
sandbox_spawn(code='...', system_prompt='Focus on data analysis.')
```

The final prompt is: `builder output + runtime system_prompt`.

## OS Provider / Filesystem

When `parentOs` is set, children get isolated filesystems:

```dart
SandboxPlugin(
  platformFactory: () async => MontyFfi(),
  parentOs: OsProvider.compose({
    'Path.': MemoryFsProvider(),
    'date.': TimeOsProvider(),
    'os.': EnvOsProvider({'KEY': 'value'}),
  }),
);
```

Each child receives:
- **Fresh `MemoryFsProvider`** — isolated VFS, no access to parent files
- **Shared `TimeOsProvider`** — same clock as parent
- **Shared `EnvOsProvider`** — same environment variables

Optional per-child working directories via `sandboxBaseDir`:
```dart
SandboxPlugin(
  sandboxBaseDir: '/workspace',
  // Children get /workspace/.sandboxes/child_0, child_1, etc.
);
```

## Platform Support

| Platform | `platformFactory` | Sandbox Support |
|----------|-------------------|-----------------|
| **FFI** (native) | `() async => MontyFfi()` | Full — spawn, gather, grandchildren |
| **WASM** (browser) | `() async => MontyWasm()` | **Limited** — see below |

### WASM Limitation

On WASM, `SandboxPlugin` creates child `MontyWasm()` instances that
share the browser's WASM Worker session. When a child disposes, it
terminates the shared Worker, killing the parent session.

**Current status:** Sandbox functions (`sandbox_spawn`, `sandbox_await`,
etc.) are not supported on WASM. The WASM Worker architecture needs
multi-session support (isolated Workers per child) to enable sandboxes.

**Workaround:** Use the JS-level `DartMontyBridge.run()` for one-shot
sandbox execution (no plugin inheritance or grandchildren). See
`repl_demo.html` for this approach.

**Planned fix:** Refactor `MontyWasm` to use `createSession()` for
each child, giving each sandbox its own Worker. The bridge JS already
supports multi-session — the Dart binding needs to use it.

## ReplSession Integration

`ReplSession` provides the simplest way to use sandboxes:

```dart
final session = ReplSession(
  plugins: [
    SandboxPlugin(
      platformFactory: () async => MontyFfi(),
      parentPlugins: [DinjaTemplatePlugin()],
    ),
    DinjaTemplatePlugin(),
  ],
);

// Python can now spawn sandboxes
final r = await session.run("sandbox_spawn(code='42')");
```

State persists across calls — sandbox handles, results, and all
other variables survive in the native Rust REPL heap.

## Architecture Diagram

```
ReplSession
  └── DefaultMontyBridge (parent)
        ├── DinjaTemplatePlugin (tmpl_render)
        ├── MessageBusPlugin (msg_send, msg_recv, ...)
        └── SandboxPlugin
              ├── sandbox_spawn → creates:
              │     └── MontyPlatform (child)
              │           └── DefaultMontyBridge (child)
              │                 ├── DinjaTemplatePlugin (inherited)
              │                 └── SandboxPlugin (depth+1, if configured)
              │                       └── sandbox_spawn → creates:
              │                             └── MontyPlatform (grandchild)
              │                                   └── ...
              ├── sandbox_await → awaits child.completer.future
              ├── sandbox_gather → Future.wait(children)
              └── sandbox_free → disposes child resources
```
