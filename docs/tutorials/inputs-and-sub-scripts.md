# Inputs, `run_script`, and Sub-Execution

This guide covers three closely-related features:

1. **`inputs:`** — inject per-call Python variables before code runs.
2. **`run_script`** — call another script from Python and receive its
   last-expression value.
3. **`HostContext.subExecute`** — drive sub-executions from your own
   host functions, safely.

All three were introduced together because they solve the same problem
from different angles: how to compose multiple Monty executions when
the bridge serialises one run at a time.

**Prerequisites:** [Host Functions — Intermediate](host-functions-intermediate.md).

---

## `inputs:` — per-call variable injection

`MontyRuntime.execute` takes an optional `Map<String, Object?> inputs`.
Each entry is converted to a Python literal and prepended to the code
as an assignment statement, so the value lands as a top-level Python
name *before* user code runs:

```dart
final r = await runtime
    .execute('f"{greeting}, {name}!"', inputs: {
      'greeting': 'hello',
      'name': 'Alice',
    })
    .result;
// r.value.dartValue == 'hello, Alice!'
```

The same parameter is on `Hhg.run(code, inputs: …)` and on
`buildRunScriptFunction`'s sub-script invocation.

### Convertible types

`bool`, `int`, `double` (incl. `nan` / `inf`), `String`, `List`, `Map`,
and `MontyNone()`. Lists and maps are converted recursively.

### Two distinct error mechanisms

Both are **synchronous** — the script never starts when the encoder
rejects an input.

| Bad input | Throws | Why |
|---|---|---|
| Dart `null` value | `MontyInternalError` | Use `MontyNone()` for Python `None`. `MontyInternalError` extends `Error` (not `Exception`), so it can't be silently swallowed by `on Exception` handlers. |
| Unsupported type (`DateTime`, custom class, etc.) | `ArgumentError` | Convert to a supported type first. |

```dart
runtime.execute('x', inputs: {'x': null});           // → MontyInternalError
runtime.execute('x', inputs: {'x': DateTime.now()}); // → ArgumentError
runtime.execute('x is None', inputs: {'x': const MontyNone()}); // OK
```

### Shared mode persistence

In shared mode (the default), injected names land in the Python
interpreter's globals — so they persist into subsequent calls on the
same runtime. Sandbox mode (`MontyRuntime(sandbox: true)`) starts each
call from a fresh interpreter, so injected names disappear after the
call returns.

---

## `run_script` — call another script from Python

`buildRunScriptFunction(readFile)` builds a `HostFunction` that lets
Python execute another script file by path:

```dart
final vfs = <String, String>{
  'greet.py': 'f"hello, {name}!"',
  'double.py': 'n * 2',
};

final runtime = MontyRuntime()
  ..register(buildRunScriptFunction((path) async {
    final code = vfs[path];
    if (code == null) throw Exception('file not found: $path');
    return code;
  }));
```

From Python:

```python
greeting = run_script('greet.py', inputs={'name': 'Alice'})
# 'hello, Alice!'

doubled = run_script('double.py', inputs={'n': 21})
# 42
```

The `readFile` callback is your wiring — point it at a `dart:io` read,
a VFS, an HTTP fetch, or whatever script source you have. It runs
synchronously from Python's perspective; awaitable Dart work in
`readFile` is fine.

### Return-value semantics

`run_script` returns whatever the sub-script's last expression
evaluates to:

| Sub-script content | `run_script(...)` returns |
|---|---|
| `n * 2` (last-expression) | the value (`42`) |
| `x = 99` (statement only) | `None` |
| `x = 7\nx * 6` (statement, then expression) | the expression value (`42`) |
| `return 42` at module level | the return value (`42`) — pydantic-monty allows it |
| Sub-script raises | the host function raises in Python; `result.isError == true` |

### Argument shape

`run_script` itself is just a host function with two params:

| Param | Type | Required |
|---|---|---|
| `path` | `string` | yes |
| `inputs` | `map` | no |

Both kwargs and positional forms work — `run_script('foo.py', inputs={'k':'v'})`
and `run_script('foo.py', {'k':'v'})` are equivalent because pydantic-monty
maps positional args to schema params by index.

Invalid arguments surface as Python errors (`result.isError == true`):

| Misuse | Surfaces as |
|---|---|
| `run_script(123)` (wrong type) | Python error |
| `run_script("f.py", inputs="oops")` (wrong type for `inputs`) | Python error |
| `run_script()` (missing required `path`) | Python error |
| `run_script("f.py", typo={…})` (unknown kwarg) | Python error |

---

## `HostContext.subExecute` — sub-execution from your own host function

Every host function handler receives a `HostContext`. Two of its fields
are the wiring for sub-execution:

```dart
class HostContext {
  // … emit, executionId, cancelToken, os …

  /// Narrow view of the owning runtime — event forwarding + schema
  /// introspection only. Deliberately does NOT expose `execute()`.
  final HostParentRef? parent;

  /// Runs a sub-script in a fresh Monty interpreter. Safe to call from
  /// inside a handler — uses an independent execution context, so it
  /// doesn't contend with the caller's bridge lock.
  final HostSubExecutor? subExecute;
}
```

### Why two fields?

The bridge serialises executions: while a script is running,
`_isExecuting` stays true through every host function dispatch.
Calling `runtime.execute()` from inside a handler would always throw
`StateError('Bridge is already executing')`.

So `HostContext` exposes only the safe surface:

- **`parent: HostParentRef?`** — `emitChildEvent` (for
  child-spawning extensions like `SandboxExtension` to forward events
  to the parent's stream) and `schemas` (for tool introspection like
  the `requires()` host function). Crucially, **no `execute()`** —
  the misuse is impossible at compile time.
- **`subExecute`** — runs sub-scripts via `Monty(code).run()` in a
  fresh interpreter. No shared state with the caller, no bridge
  contention, returns a `MontyResult`.

### Building your own `run_script`-style function

```dart
HostFunction myEvalFn() {
  return HostFunction(
    schema: const HostFunctionSchema(
      name: 'evaluate',
      description: 'Run a snippet and return its last expression.',
      params: [
        HostParam(name: 'code', type: HostParamType.string),
        HostParam(
          name: 'inputs',
          type: HostParamType.map,
          isRequired: false,
        ),
      ],
    ),
    handler: (args, ctx) async {
      final subExecute = ctx.subExecute;
      if (subExecute == null) {
        throw StateError('evaluate: no subExecute wired into HostContext');
      }
      final code = args['code']! as String;
      final rawInputs = args['inputs'];
      final inputs = rawInputs is Map
          ? rawInputs.map((k, v) => MapEntry(k.toString(), v as Object?))
          : null;

      final result = await subExecute(code, inputs: inputs);
      if (result.isError) {
        throw Exception('evaluate failed: ${result.error?.message}');
      }
      return result.value.dartValue;
    },
  );
}
```

### What you trade for safety

`subExecute` runs in a **fresh interpreter** — variables, functions,
imports from the caller are not visible to the sub-script. If you need
the sub-script to see the caller's state, you have to inject it
explicitly via `inputs:` (or accept that the sub-script can only call
the same host functions, since those are wired through every Monty
execution).

This is by design: nested execution on the same Python interpreter is
the deadlock scenario, so the API doesn't offer it.

---

## Putting it together

A typical pattern: the LLM generates a small helper script that
needs to call back into a curated set of Dart functions. The IDE wires
that pattern with three pieces:

```dart
final runtime = MontyRuntime()
  // 1. Register the helpers — visible in both the main script and any
  //    script run via run_script.
  ..register(myEvalFn())
  ..register(buildRunScriptFunction((path) => vfs.readFile(path)));

// 2. Inject context into the main script before it runs.
final r = await runtime
    .execute(mainScript, inputs: {'session_id': sessionId})
    .result;
```

Inside `mainScript`, Python can call `run_script('helper.py', inputs={…})`
to dispatch into a separate file, with the helper's own injected
inputs. Each helper runs in its own fresh interpreter via `subExecute`
— no deadlock, no leakage, no surprises.
