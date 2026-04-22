# Monty API — Dart

Sandboxed Python interpreter for Dart and Flutter. Pure Dart, no Flutter
required.

## MontyRuntime (Recommended)

`MontyRuntime` is the high-level API for stateful Python execution with
tools, extensions, and OS-level interception.

```dart
final session = MontyRuntime(
  extensions: [JinjaTemplateExtension()],
  osHandlers: {'Path.': memoryFsHandler()},
);

// Variables persist natively across calls
await session.execute('x = 42').result;
final r = await session.execute('x + 1').result;
print(r.value); // 43

await session.dispose();
```

### Execution Modes

- **Shared Mode** (default): One interpreter persists across all calls.
  Variables and functions survive in the Rust heap.
- **Sandbox Mode** (`sandbox: true`): Each call creates and disposes a
  fresh interpreter. Safe for async I/O host functions.

## Monty (Low-level)

The `Monty` class provides a simple stateful REPL wrapper from `dart_monty_core`.

```dart
final monty = Monty();
final r = await monty.run('import pathlib; x=1');
await monty.dispose();
```

One-shot execution:
```dart
final result = await Monty.exec('2 + 2');
```

## Host Functions

Expose Dart code to Python:

```dart
HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Fetch URL content.',
    params: [HostParam(name: 'url', type: HostParamType.string)],
  ),
  handler: (args, ctx) async => http.read(Uri.parse(args.str('url'))),
)
```

## Extensions

Group related tools into namespaced units.

| Extension | Description |
|-----------|-------------|
| `JinjaTemplateExtension` | Jinja2 template rendering |
| `MessageBusExtension` | In-memory message channels |
| `SandboxExtension` | Recursive child interpreters |
| `EventLoopExtension` | Long-running coroutine exchange |

## OS Call Handlers

Intercept Python `pathlib`, `os`, and `datetime` calls.

| Handler | Description |
|---------|-------------|
| `fsHandler(FileSystem)` | Generic Path.* handler |
| `memoryFsHandler()` | Ephemeral in-memory VFS |
| `sandboxedFsHandler(root)`| Restricted native FS |
| `readOnlyHandler(child)` | Blocks write operations |
| `overlayFsHandler()` | Copy-on-write overlay |
| `composeOsHandlers({})` | Prefix-based dispatch |

## Core Types

- `MontyResult`: `.value`, `.error`, `.usage`, `.printOutput`
- `MontyException`: `.message`, `.excType`, `.traceback`
- `MontyValue`: Sealed hierarchy representing Python objects (Int, String, List, Map, etc.)
- `BridgeEvent`: Sealed hierarchy for execution observability.
