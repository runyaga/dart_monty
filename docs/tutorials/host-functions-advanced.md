# Host Functions - Advanced

This guide covers child Python executions, resource limits, async host
functions, progress events, cancellation, and sub-execution.

**Prerequisites:** Read the [Intermediate guide](host-functions-intermediate.md) first.

## SandboxExtension

`SandboxExtension` is a `MontyExtension` that exposes child Python execution
to a parent script. Each child has an independent interpreter state and a
`MontyBridge`.

Create the extension when starting the runtime:

```dart
final runtime = await MontyRuntime.start(
  extensions: [
    SandboxExtension(
      maxChildren: 16,
      maxDepth: 3,
      childLimits: const ResourceLimits(
        maxFeedDuration: Duration(seconds: 5),
        maxMemory: 10 * 1024 * 1024,
      ),
    ),
  ],
);
```

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `maxChildren` | `int` | `16` | Maximum admitted child handles |
| `maxDepth` | `int` | `3` | Maximum depth for nested child execution |
| `currentDepth` | `int` | `0` | Depth of this extension instance |
| `childLimits` | `ResourceLimits?` | `null` | Limits selected for child sessions |
| `sandboxBaseDir` | `String?` | `null` | Native backing directory for child workspaces on the VM |
| `writeBytesLimit` | `int?` | `8388608` | Cumulative child workspace write limit |
| `memoryUsageLimit` | `int?` | `8388608` | Retained child workspace content limit |

`ResourceLimits` supports `maxFeedDuration`, `maxTurnDuration`, `maxMemory`,
`gcInterval`, `maxRecursionDepth`, `maxSuspensions`, and `maxTotalSleep`.
When `childLimits` is absent, a child uses the runtime limits. A child may
reduce `maxFeedDuration` with `timeout_ms` and `maxMemory` with `memory_bytes`.

### Host functions provided

The extension registers these Python functions:

| Function | Description |
|----------|-------------|
| `sandbox_spawn(code, timeout_ms=?, memory_bytes=?, files=?, ro_files=?)` | Starts a child and returns an integer handle. |
| `sandbox_await(handle, collect=?)` | Waits for a child and returns its value. |
| `sandbox_await_all(handles)` | Waits for children and returns their values in handle order. |
| `sandbox_is_alive(handle)` | Reports whether a child is executing. |
| `sandbox_free(handle)` | Releases a handle and cancels its child when it is executing. |
| `sandbox_get_output(handle)` | Returns captured `print()` output after completion. |
| `sandbox_gather(handles)` | Returns dictionaries containing each handle, value, and output. |

### Child execution from Python

```python
first = sandbox_spawn(code='sum(range(1000))')
second = sandbox_spawn(code='sum(range(2000))')

results = sandbox_gather(handles=[first, second])
sandbox_free(handle=first)
sandbox_free(handle=second)
results
```

Child handles remain admitted until `sandbox_free` releases them. Freeing an
executing handle cancels its child. `sandbox_await` raises a Python error when
the child fails.

### Extension inheritance

Children receive independent instances from extensions that select
`ChildPolicy.clone` and implement `createChildInstance`. Extensions selecting
`ChildPolicy.inherit` share their instance with children, while
`ChildPolicy.exclude` keeps an extension out of child runtimes.
`SandboxExtension` uses `currentDepth` and `maxDepth` to bound nested child
execution.

## Async host functions

Set `dispatch` to `DispatchMode.future` when Python calls the function with
`await`. A handler receives `HostContext`, which provides `emitText`, an
execution-scoped `cancelToken`, and `subExecute` for an independent Python
execution.

```dart
HostFunction delayedEcho() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'delayed_echo',
    params: [HostParam(name: 'text', type: HostParamType.string)],
  ),
  dispatch: DispatchMode.future,
  handler: (args, context) async {
    context.emitText('starting');
    await Future.any<void>([
      Future<void>.delayed(const Duration(milliseconds: 10)),
      context.cancelToken.future,
    ]);
    if (context.cancelToken.isCancelled) {
      throw StateError('execution cancelled');
    }
    return args['text']!;
  },
);

final runtime = await MontyRuntime.start();
runtime.register(delayedEcho());
final value = await runtime.execute('await delayed_echo("hello")').result;
await runtime.dispose();
```

`HostContext.emit` accepts any `BridgeEvent`. `emitText` creates a
`BridgeFunctionEmit` event for progress text. `ExecutionHandle.cancel` signals
the context token, and handlers decide how to stop their own pending work.

## Sub-execution from a host function

`HostContext.subExecute` runs code in a fresh session. It returns a
`MontyValue`, accepts optional `Map<String, MontyValue>` inputs, and does not
share the caller's Python globals or registered host functions.

```dart
HostFunction evaluate() => HostFunction(
  schema: const HostFunctionSchema(
    name: 'evaluate',
    params: [HostParam(name: 'code', type: HostParamType.string)],
  ),
  handler: (args, context) async {
    final subExecute = context.subExecute;
    if (subExecute == null) throw StateError('sub-execution is unavailable');
    final code = (args['code']! as MontyString).value;
    return subExecute(code, inputs: {'n': const MontyInt(21)});
  },
);
```

`subExecute` needs another available session from the runtime pool. Supply a
pool with capacity for the parent execution and each concurrent child or
sub-execution.
