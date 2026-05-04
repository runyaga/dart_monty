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

## Per-call inputs

`MontyRuntime.execute(code, inputs: {…})` and `Hhg.run(code, inputs: {…})`
inject Python variables before user code runs:

```dart
await runtime
    .execute('f"{greeting}, {name}!"', inputs: {
      'greeting': 'hello',
      'name': 'Alice',
    })
    .result;
```

Convertible types: `bool`, `int`, `double`, `String`, `List`, `Map`,
and `MontyNone()`. Dart `null` throws `MontyInternalError` (use
`MontyNone()` for Python `None`); unsupported types throw
`ArgumentError`. Both are synchronous — the script never starts.

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

`ctx` (`HostContext`) exposes:

| Field | Purpose |
|-------|---------|
| `emit` / `emitText` | Push `BridgeEvent`s mid-call (progress, custom events) |
| `executionId` | Per-call ID for event correlation |
| `cancelToken` | Cooperative cancellation for long-running work |
| `os` | Active `OsCallHandler`, for direct OS-primitive calls |
| `parent: HostParentRef?` | Narrow view of the owning runtime — `emitChildEvent`, `schemas`. **No `execute()`** (would deadlock). |
| `subExecute` | Run a sub-script in a fresh interpreter. See `buildRunScriptFunction` and the [tutorial](../tutorials/inputs-and-sub-scripts.md). |

### `buildRunScriptFunction`

Convenience builder for a `run_script` host function — Python calls
`run_script('foo.py', inputs={…})` and gets back the sub-script's
last-expression value:

```dart
runtime.register(buildRunScriptFunction((path) async {
  return await File(path).readAsString();
}));
```

See the [Inputs, `run_script`, and Sub-Execution tutorial](../tutorials/inputs-and-sub-scripts.md)
for the full story.

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
