# Monty API — Dart

Sandboxed Python interpreter for Dart and Flutter. Pure Dart, no Flutter
required.

## MontyRuntime (Recommended)

`MontyRuntime` is the high-level API for stateful Python execution with
tools, extensions, and OS-level interception.

```dart
import 'package:dart_monty/dart_monty.dart';

final session = await MontyRuntime.start(
  extensions: [EventLoopExtension()],
  osHandlers: {'Path.': OSAccess().call},
);

// Variables persist natively across calls
await session.execute('x = 42').result;
final r = await session.execute('x + 1').result;
print(r.dartValue); // 43

await session.dispose();
```

### Execution Modes

- **Shared Mode** (default): One interpreter persists across all calls.
  Variables and functions survive in the Rust heap.
- **Sandbox Mode** (`sandbox: true`): Each call creates and disposes a
  fresh interpreter. Safe for async I/O host functions.

## Monty (Low-level)

`Monty` owns a pool; `MontySession` owns stateful Python execution.

```dart
await Monty.withPool((pool) async {
  final session = await pool.checkout(typeCheck: true);
  try {
    await session.feedRun('x: int = 42');
    final result = await session.feedRun('x + 1');
    print(result.dartValue); // 43
  } finally {
    await session.close();
  }
});
```

### Session type checking

`checkout(typeCheck: true)` checks each feed before executing it. Rejected
code throws `MontyTypingError`; import that error from
`package:dart_monty_core/dart_monty_core.dart`. Use `typeCheckStubs` on checkout
to declare external names, for example `def fetch(url: str) -> str: ...`.
The [type-checking demo](../../example/type_check_demo.dart) shows clean code,
type errors, and host function declarations.

## Per-call inputs

`MontyRuntime.execute(code, inputs: {…})` injects Python variables
before user code runs:

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
  handler: (args, ctx) async => MontyString(
    await http.read(Uri.parse((args['url']! as MontyString).value)),
  ),
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
| `SandboxExtension` | Recursive child interpreters |
| `EventLoopExtension` | Long-running coroutine exchange |

## OS Call Handlers

Intercept Python `pathlib` and `os` calls. The clock is answered by the worker, not by a handler.

`OSAccess` comes from `package:dart_monty/dart_monty.dart`. Import `MemoryFile`
directly from `package:dart_monty_core/dart_monty_core.dart`. Register
`OSAccess.call` with `registerOs`, or use its callback in `osHandlers`. `OSAccess(files: [...],
environ: {...})` supplies memory files and environment values. Create parent
directories before writing new files.

Sandbox workspaces default to `/work` and 8 MiB each for cumulative
write bytes and retained logical memory. `SandboxExtension(writeBytesLimit:,
memoryUsageLimit:)` accepts explicit null to opt out of a counter. Negative
values are rejected. See [workspace policy](../deep-dives/oscall-vfs.md).
On VM, `sandboxBaseDir` selects a fresh owned native directory retained until
free/disposal. Web refuses host backing; omit the option for memory workspaces.
D5 uses either backing for live child checkout.

## Core Types

- `MontyResult`: `.value`, `.error`, `.usage`, `.printOutput`
- `MontyException`: `.message`, `.excType`, `.traceback`
- `MontyValue`: Sealed hierarchy representing Python objects (Int, String, List, Map, etc.)
- `BridgeEvent`: Sealed hierarchy for execution observability.
