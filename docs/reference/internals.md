# Internals

This page describes the package structure that supports the public
`package:dart_monty/dart_monty.dart` API.

## Package boundary

`dart_monty_core` provides the worker pool, sessions, Python values, resource
limits, errors, and OS-handler types. `dart_monty` builds runtime execution,
host-function dispatch, extensions, bridge events, and browser or native
backend selection on those types.

Applications import `package:dart_monty/dart_monty.dart`. The facade exports
the runtime API together with its supported core types. Source libraries under
`lib/src/` implement the package and do not form an application API.

## Runtime sessions

`MontyRuntime.start` creates a runtime from an optional `Monty` pool. Without
an injected pool, the runtime starts and owns a pool sized for a root
execution, a sub-execution, and configured sandbox children. The pool supplies
`MontySession` instances.

Shared mode holds one session and preserves Python state between executions.
Fresh-session mode, selected with `sandbox: true`, checks out a session for
each execution and closes it after completion. `clearState()` creates an empty
shared session. `dispose()` closes live sessions and extensions, then closes an
owned pool.

## Bridge execution and host functions

`MontyBridge` adapts one `MontySession` to a stream of `BridgeEvent`s. It runs
Python code, collects printed output, routes OS calls, and dispatches host
functions. `ExecutionHandle` exposes an execution identifier, event stream,
result future, and cancellation operation.

`HostFunction` pairs a `HostFunctionSchema` with a handler. A schema declares
the function name and ordered `HostParam` definitions. The bridge validates
arguments and invokes the handler with named `MontyValue` arguments and a
`HostContext`.

```dart
import 'package:dart_monty/dart_monty.dart';

final greeting = HostFunction(
  schema: const HostFunctionSchema(
    name: 'greet',
    params: [HostParam(name: 'name', type: HostParamType.string)],
  ),
  handler: (args, _) async {
    final name = (args['name']! as MontyString).value;
    return MontyString('Hello, $name');
  },
);
```

## Extensions and OS handlers

`MontyExtension` supplies host functions and optional OS-handler
contributions. The runtime attaches extensions before their first execution or
direct host-function invocation. It disposes them with the runtime.

`SandboxExtension` exposes child execution facilities to Python. Its child
limits, child count, depth, and filesystem bounds configure those children.
`EventLoopExtension` supplies event-loop operations and records its latest
emitted signal.

`OsHandler` receives OS calls in the core value format. `OSAccess` supplies an
OS handler for configured filesystem access. A runtime accepts one `os`
handler or a prefix-keyed `osHandlers` map.

## Resource and error flow

`ResourceLimits` applies to sessions used for root execution. An execution
result completes with a `MontyValue`. Python failures complete it with a
`MontyError` subclass. Host handlers use `ExternalException` to report an
external exception type and message to Python.
