# Inputs, `run_script`, and Sub-Execution

This guide covers per-execution inputs, the `run_script` host function, and
sub-execution from host functions.

**Prerequisites:** [Host Functions - Intermediate](host-functions-intermediate.md).

---

## `inputs:` per-execution variable injection

`MontyRuntime.execute` accepts `Map<String, Object?>` inputs. Each value
becomes a top-level Python variable before the code runs.

```dart
final runtime = await MontyRuntime.start(
  extensions: [SandboxExtension()],
);
final result = await runtime
    .execute(
      'f"{greeting}, {name}!"',
      inputs: {'greeting': 'hello', 'name': 'Alice'},
    )
    .result;
print(result.dartValue);
await runtime.dispose();
```

Input values support `bool`, `int`, `double`, `String`, `List`, `Map`, and
`MontyNone()`, including nested lists and maps. Dart `null` and `MontyNone()`
both become Python `None`.

The default runtime retains Python globals between executions. Set
`sandbox: true` on `MontyRuntime.start` to execute each call in a fresh
session.

## `run_script` calls another script

`buildRunScriptFunction` creates a host function that loads source by path and
runs it through `HostContext.subExecute`.

```dart
final scripts = <String, String>{
  'greet.py': 'f"hello, {name}!"',
};

final runtime = await MontyRuntime.start();
runtime.register(
  buildRunScriptFunction((path) {
    final code = scripts[path];
    if (code == null) throw StateError('script not found: $path');
    return code;
  }),
);

final result = await runtime
    .execute('run_script("greet.py", inputs={"name": "Alice"})')
    .result;
print(result.dartValue);
await runtime.dispose();
```

The Python function takes a required string `path` and an optional map
`inputs`. Its result is the sub-script's last expression. A sub-script runs in
a fresh session, so its globals do not enter the caller's session and it does
not receive the caller's host functions.

```python
greeting = run_script('greet.py', inputs={'name': 'Alice'})
```

`inputs` keys must be string Python identifiers that are not keywords. Invalid
arguments and failures from the source loader surface as Python errors.

## `HostContext.subExecute` from your own host function

Every host function handler receives `HostContext`. `subExecute` runs a
sub-script in a fresh session and returns its `MontyValue` result. It is
available on a runtime-backed handler.

```dart
HostFunction doubleValue() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'double_value',
    params: [HostParam(name: 'value', type: HostParamType.integer)],
  ),
  handler: (args, context) async {
    final subExecute = context.subExecute;
    if (subExecute == null) throw StateError('sub-execution is unavailable');
    return subExecute('value * 2', inputs: {'value': args['value']!});
  },
);
```

`HostContext.parent` provides event forwarding and function schemas.
`HostContext.cancelToken` signals cancellation for the current execution.
Use `subExecute` for nested Python work instead of calling the owning runtime
from a host function.

## Sync and async handlers

`HostFunction` handlers return `Future<MontyValue>`. `DispatchMode.sync`
exposes a regular Python call. `DispatchMode.future` exposes an awaitable for
Python `await` and `asyncio.gather`.
