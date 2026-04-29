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

### What `execute()` returns

`runtime.execute(code)` returns an `ExecutionHandle`, **not** a
`Future<MontyResult>` and **not** a `Stream<BridgeEvent>`. The handle
exposes:

- **`.result`** — `Future<MontyResult>` for the final value. Most
  callers use this: `final r = await runtime.execute(code).result;`.
- **`.events`** — `Stream<BridgeEvent>` for streaming progress
  (host-function calls, OS calls, intermediate emits). Use this when
  you want a UI to update mid-call. See
  [host-functions-beginner.md](../tutorials/host-functions-beginner.md#the-bridgeevent-stream)
  for the full event taxonomy.
- **`.cancel()`** — abort an in-flight execution.

`MontyResult` (returned by `.result`) carries:

- **`.value`** — the Python return value as a typed `MontyValue`
  subtype: `MontyString`, `MontyInt`, `MontyList`, `MontyDict`, etc.
  Pattern-match on the type or call `.toJson()` to get a plain
  Dart `Object?`. **It is NOT plain Dart automatically** — older
  docs claimed `.value` was unwrapped; that's wrong, you must
  unwrap explicitly.
- **`.montyValue`** — alias for `.value`. Both expose the same
  typed wrapper. Use whichever name reads better at the call
  site.
- **`.printOutput`** — captured `print()` output as a `String?`.
- **`.error`** — `MontyException?` if the script raised; `null`
  on success. **Errors come back as a field on the result, not as a
  thrown exception.**

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

`Monty.typeCheck` analyses code without executing it. **It is a
type-and-name resolver, NOT a subset-feature gate.**

```dart
final errors = await Monty.typeCheck('x: int = "not an int"');
for (final e in errors) {
  print('${e.path}:${e.line}:${e.column} ${e.code}: ${e.message}');
}
```

#### What typeCheck catches

- **Type mismatches** between declarations and assignments
  (e.g. `x: int = "hi"`).
- **Unresolved references** — names used but never defined or
  declared in `prefixCode`.

#### What typeCheck does NOT catch

> **Subset violations pass typeCheck silently.** `class`,
> `match`/`case`, `yield`, and `del` all return 0 errors from
> `typeCheck` and only surface at `runtime.execute` time as
> `MontyException: NotImplementedError: The monty syntax parser
> does not yet support …`. If you treat typeCheck as a complete
> pre-flight gate, your script will still hit this surprise at
> runtime.

The recommended pattern is the **dual-validation loop**:

```dart
// 1. typeCheck — catches type errors and unresolved names.
final errs = await Monty.typeCheck(userCode, prefixCode: prefixCode);
if (errs.isNotEmpty) return;

// 2. Execute — surfaces subset violations as result.error.
final result = await runtime.execute(userCode).result;
if (result.error != null) {
  // Likely NotImplementedError: subset feature used (class/match/yield/del).
  return;
}
```

This split is by design: typeCheck runs in an isolated analysis
heap with no host functions registered, so it can't safely execute
arbitrary code paths to discover subset violations. The runtime
parser is the authoritative subset enforcer.



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
> def msg_recv(name: str, timeout_ms: int | None = None) -> object: return None
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
> **Default values must match the parameter type.** `def fetch(timeout_ms:
> int = None)` is rejected — `None` is not an `int`. If a parameter
> is genuinely optional, declare it as `int | None = None` (or use
> `Optional[int]` if you prefer). For required parameters, omit the
> default. The same rule applies to every typed parameter in
> `prefixCode` stubs.
>
> Rule of thumb: if a name is in scope at `runtime.execute(...)` time
> but not in the standard Monty stdlib (`json`, `math`, `re`,
> `pathlib`, `datetime`, `collections`), it needs a stub. See
> `example/type_check_demo.dart` for a working reference.

## Host Functions

Expose Dart code to Python. Handler signature is
`Future<Object?> Function(Map<String, Object?> args, HostContext ctx)`:

```dart
HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Fetch URL content.',
    params: [HostParam(name: 'url', type: HostParamType.string)],
  ),
  // args is a plain Map<String, Object?> — access by key + cast.
  // There is no `args.str(...)` / `args.int(...)` helper.
  handler: (args, ctx) async {
    final url = args['url'] as String;
    return http.read(Uri.parse(url));
  },
)
```

The schema's `HostParamType` is for Python-side validation (rejects
mistyped input before your handler runs); the handler still has to
cast each value in Dart because `Map<String, Object?>` is dynamic on
the Dart side. Use `args['name'] as String`, `args['n'] as num`,
`args['items'] as List`, etc.

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
