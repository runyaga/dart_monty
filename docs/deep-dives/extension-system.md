# Extension System

The extension system exposes Dart capabilities to Python execution. An
extension contributes host functions, attachment hooks, and optional OS-call
handlers to a `MontyRuntime`.

## Guides

| Level | Document | Focus |
|---|---|---|
| Intro | [Host Functions Intro](../tutorials/host-functions-intro.md) | Host functions and schemas |
| Beginner | [Host Functions Beginner](../tutorials/host-functions-beginner.md) | Parameters, validation, errors, and bridge events |
| Intermediate | [Host Functions Intermediate](../tutorials/host-functions-intermediate.md) | Extensions, lifecycle hooks, and event-loop integration |
| Advanced | [Host Functions Advanced](../tutorials/host-functions-advanced.md) | Child execution, limits, and workspace policy |

## Architecture at a Glance

```text
+--------------------------------------------------+
| MontyRuntime                                     | runtime lifecycle and execution
+--------------------------------------------------+
| MontyExtension and AttachContext                 | capabilities and attachment hooks
+--------------------------------------------------+
| HostFunction, HostFunctionSchema, HostParam      | callable Python-facing functions
+--------------------------------------------------+
| MontyBridge and BridgeEvent                      | dispatch and execution events
+--------------------------------------------------+
| Monty, MontySession, MontyValue                  | core pool, session, and values
+--------------------------------------------------+
```

`MontyExtension` declares a unique namespace and a list of host functions.
The runtime attaches each extension and calls `onAttach` with an
`AttachContext`. The context exposes registered schemas and `registerOs` for
OS handler registration. `onDispose` releases extension-owned resources.

```dart
import 'package:dart_monty/dart_monty.dart';

class SharedExtension extends MontyExtension {
  @override
  String get namespace => 'shared';

  @override
  List<HostFunction> get functions => const [];

  @override
  ChildPolicy get childPolicy => ChildPolicy.inherit;
}
```

## Child Extension Policy

`ChildPolicy` controls an extension's participation in a child created by
`SandboxExtension`.

- `ChildPolicy.exclude` omits the extension from child execution.
- `ChildPolicy.clone` requires `createChildInstance(ChildSpawnContext)` to
  return a distinct extension instance.
- `ChildPolicy.inherit` attaches the parent extension instance to the child.

`ChildSpawnContext` contains the child identifier and its virtual working
directory. A cloned extension can use this context to configure state for one
child. An inherited extension must tolerate attachment to each child that
shares it.

## Host Functions

`HostFunction` combines a `HostFunctionSchema` with a handler. The schema
describes the function name and `HostParam` values. The handler receives typed
`MontyValue` arguments and returns a `Future<MontyValue>`. `MontyRuntime.register`
adds a function after startup.

Most applications pass extensions to `MontyRuntime.start`. The runtime
attaches them before shared execution and disposes them when the runtime
ends.
