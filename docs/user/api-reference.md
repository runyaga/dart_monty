# Monty API for Dart

`dart_monty` provides a sandboxed Python runtime for Dart and Flutter.

## MontyRuntime

`MontyRuntime` runs stateful Python code with host functions, extensions, and
OS interception.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  final runtime = await MontyRuntime.start(
    extensions: [EventLoopExtension()],
    osHandlers: {'Path.': OSAccess().call},
  );
  try {
    await runtime.execute('x = 42').result;
    final value = await runtime.execute('x + 1').result;
    print(value.dartValue); // 43
  } finally {
    await runtime.dispose();
  }
}
```

### Execution Modes

- **Shared mode** is the default. One interpreter holds variables and
  functions across executions.
- **Sandbox mode** uses a fresh interpreter for each execution. Set
  `sandbox: true` in `MontyRuntime.start`.

## Monty

`Monty` owns a pool and `MontySession` runs stateful Python execution.

```dart
import 'package:dart_monty/dart_monty.dart';

Future<void> main() async {
  await Monty.withPool((pool) async {
    final session = await pool.checkout(typeCheck: true);
    try {
      await session.feedRun('x: int = 42');
      final value = await session.feedRun('x + 1');
      print(value.dartValue); // 43
    } finally {
      await session.close();
    }
  });
}
```

### Session type checking

`checkout(typeCheck: true)` checks each feed before execution. A rejected feed
throws `MontyTypingError`, which comes from
`package:dart_monty_core/dart_monty_core.dart`. Use `typeCheckStubs` on
checkout to declare external names. The
[type-checking demo](../../example/type_check_demo.dart) includes examples.

## Per-call inputs

`MontyRuntime.execute` binds `inputs` as Python globals before execution.

```dart
final value = await runtime
    .execute(
      'f"{greeting}, {name}!"',
      inputs: {'greeting': 'hello', 'name': 'Alice'},
    )
    .result;
print(value.dartValue); // hello, Alice!
```

Input values accept `bool`, `int`, `double`, `String`, `List`, `Map`, and
`MontyNone()`. Dart `null` converts to `MontyNone`.

## Host Functions

`HostFunction` exposes a Dart callback to Python.

```dart
final fetch = HostFunction(
  schema: const HostFunctionSchema(
    name: 'fetch',
    description: 'Return content for a URL.',
    params: [HostParam(name: 'url', type: HostParamType.string)],
  ),
  handler: (args, _) async {
    final url = (args['url']! as MontyString).value;
    return MontyString('content for $url');
  },
);
runtime.register(fetch);
```

`HostContext` supplies the active `OsHandler` through `os`, an execution ID,
a cancellation token, event emission, and an optional sub-executor. Its
`parent` exposes child-event forwarding and schemas.

### `buildRunScriptFunction`

`buildRunScriptFunction` creates a `run_script` host function. The callback
maps a requested path to source code, and the sub-script returns its final
expression value.

```dart
runtime.register(buildRunScriptFunction((_) async => '40 + 2'));
```

See the [Inputs, `run_script`, and Sub-Execution tutorial](../tutorials/inputs-and-sub-scripts.md).

## Extensions

Extensions group related host functions and OS policy.

| Extension | Description |
| --- | --- |
| `SandboxExtension` | Manages recursive child interpreters. |
| `EventLoopExtension` | Exchanges events with long-running coroutines. |

## OS Call Handlers

An `OsHandler` intercepts Python `pathlib` and `os` calls. `OSAccess` is
available from `package:dart_monty/dart_monty.dart` and supplies an in-memory
filesystem and environment values. Pass `OSAccess().call` as `os` or through
`osHandlers` when starting a runtime. `MemoryFile` comes from
`package:dart_monty_core/dart_monty_core.dart`.

`ExternalException` communicates an external OS error to Python.
`OsCallNotHandledException` declines an operation so another handler can
answer it.

## Core Types

- `MontyValue` represents a Python value. Its facade value types include
  `MontyBool`, `MontyInt`, `MontyFloat`, `MontyString`, `MontyList`,
  `MontyTuple`, `MontyDict`, and `MontyBytes`.
- `ExecutionHandle` exposes `result`, `events`, `executionId`, and `cancel`.
  `result` completes with a `MontyValue` or fails with a `MontyError` subclass.
- `MontyError` and its subclasses come from `dart_monty_core`.
- `ResourceLimits` configures runtime resource limits.
- `BridgeEvent` is the event hierarchy for execution observation.
