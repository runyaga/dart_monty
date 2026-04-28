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

`Monty` from `dart_monty_core` is the low-level execution surface. It has
three shapes:

```dart
// One-shot, stateless.
final result = await Monty.exec('2 + 2');

// Compiled-program holder — re-run with different inputs.
final program = Monty('x * 2');
final r1 = await program.run(inputs: {'x': 21});
final r2 = await program.run(inputs: {'x': 100});

// Stateful REPL — variables, functions, classes persist across calls.
final repl = MontyRepl();
await repl.feedRun('x = 42');
final r3 = await repl.feedRun('x + 1');
await repl.dispose();
```

Each `Monty(code).run(...)` call runs in a fresh interpreter — state from
earlier calls does not persist. Use `MontyRepl` when you need accumulated
state.

### Static type checking

`Monty.typeCheck` analyses code without executing it:

```dart
final errors = await Monty.typeCheck('x: int = "not an int"');
for (final e in errors) {
  print('${e.path}:${e.line}:${e.column} ${e.code}: ${e.message}');
}
```

`prefixCode` lets you declare input or external-function shapes so the
checker knows their types:

```dart
final errors = await Monty.typeCheck(
  'result: str = fetch("https://example.com")',
  prefixCode: 'def fetch(url: str) -> str: ...',
);
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
