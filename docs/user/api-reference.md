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

### Resource Limits with MontyRuntime

`MontyRuntime` does **not** accept a `limits` parameter — neither on
the constructor nor on `execute()`. If you need memory / wall-clock /
stack-depth caps, use one of these instead:

- **`Monty.exec(code, limits: MontyLimits(...))`** — one-shot,
  stateless execution with the limits applied to that single call.
- **`MontyRepl(limits: MontyLimits(...))`** — stateful REPL where
  every `feedRun()` runs under the same limit envelope.
- **`SandboxExtension(childLimits: MontyLimits(...))`** — when
  spawning child interpreters from inside a `MontyRuntime`, the
  children get limits even though the parent runtime does not. See
  the Sandbox section in [Extensions](extensions.md).

If your use case needs a stateful runtime with limits and host
function tools, the recommended pattern is:

1. Create a `MontyRuntime` for tool/extension wiring.
2. Spawn child interpreters via `SandboxExtension(childLimits: ...)`
   for the actual user-script execution.
3. The runtime's parent interpreter remains uncapped (it only
   coordinates; user scripts run in capped children).

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

`prefixCode` declares input or external-function shapes so the
checker knows their types:

```dart
final errors = await Monty.typeCheck(
  'result: str = fetch("https://example.com")',
  prefixCode: 'def fetch(url: str) -> str: return ""',
);
```

> **`prefixCode` is required when the script calls host functions or
> extension functions.** The type checker has no built-in knowledge
> of names introduced by the bridge — `tmpl_render`, `msg_send`,
> `sandbox_spawn`, host functions you register via `HostFunction(...)`,
> etc. Without a stub for each, `Monty.typeCheck` reports
> `unresolved-reference` for those names and you'll see false
> positives that look like bugs in your script. Stub every name your
> script will reach at runtime:
>
> ```dart
> const prefixCode = '''
> # Built-in extension functions
> def tmpl_render(template: str, context: dict) -> str: return ""
> def msg_send(name: str, message) -> None: return None
> def msg_recv(name: str, timeout_ms: int = None) -> object: return None
>
> # Your host functions (one stub per HostFunction registered on the runtime)
> def fetch(url: str) -> str: return ""
> def write_log(level: str, message: str) -> None: return None
> ''';
>
> final errors = await Monty.typeCheck(userCode, prefixCode: prefixCode);
> ```
>
> **Body must be an actual statement, not Ellipsis.** Monty's Python
> subset does not accept `def f(): ...` — that triggers an empty-body
> error and the stub is rejected. Use a literal return value matching
> the declared return type: `return ""` for `str`, `return 0` for
> `int`, `return None` for `None`, `return []` for `list`, etc. The
> value is never executed (the real implementation runs at
> `runtime.execute(...)` time); it just satisfies Monty's parser.
>
> Rule of thumb: if a name is in scope at `runtime.execute(...)` time
> but not in the standard Monty stdlib (`json`, `math`, `re`,
> `pathlib`, `datetime`, `collections`), it needs a stub. See
> `example/type_check_demo.dart` for a working reference.

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
