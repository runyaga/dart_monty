# Error Hierarchy and Control Flow

## Sealed Error Hierarchy

Core exposes `MontyError` as the common exception type for a failed session
feed. Its sealed subclasses identify parse failures, Python runtime failures,
type-check failures, and sessions whose worker stops.

```dart
import 'package:dart_monty/dart_monty.dart';
import 'package:dart_monty_core/dart_monty_core.dart'
    show
        MontyCrashedError,
        MontyRuntimeError,
        MontySyntaxError,
        MontyTypingError;

String describe(MontyError error) => switch (error) {
  MontySyntaxError() => error.exception.excType,
  MontyRuntimeError() => error.exception.excType,
  MontyTypingError() => error.exception.excType,
  MontyCrashedError() => error.exception.excType,
};

Future<void> main() async {
  final runtime = await MontyRuntime.start();
  try {
    await runtime.execute('1 / 0').result;
  } on MontyError catch (error) {
    if (describe(error).isEmpty) return;
  } finally {
    await runtime.dispose();
  }
}
```

## Type Relationships

```text
Exception (dart:core)
  └── MontyError (sealed)
        ├── MontySyntaxError
        ├── MontyRuntimeError
        ├── MontyTypingError
        └── MontyCrashedError
```

Every `MontyError` has an `exception` value with `excType` and `message`.
`MontySyntaxError` and `MontyRuntimeError` also expose `traceback` and
`display()`. `MontyTypingError` exposes `display()`. `MontyCrashedError`
exposes `timedOut` and `exitStatus`.

## Error Source to Sealed Type Mapping

| Source | Error type | Session state |
|---|---|---|
| Python parser rejects a feed | `MontySyntaxError` | Session remains available |
| Python code raises an uncaught exception | `MontyRuntimeError` | Session remains available unless the runtime discards it after a terminal resource failure |
| Session type check rejects a feed | `MontyTypingError` | Session remains available |
| Worker exits, reaches a deadline, or violates the transport protocol | `MontyCrashedError` | Session is unusable |

## Control Flow Through Boundaries

```text
Python feed
  │
  ▼
MontySession reports a value or MontyError
  │
  ▼
MontyBridge emits BridgeRunFinished or BridgeRunError
  │
  ▼
MontyRuntime completes ExecutionHandle.result with a MontyValue or error
```

`BridgeRunError.exception` carries the `MontyError` for an error that comes
from Python or the session. `BridgeRunError.message` provides the rendered
message for event consumers. Infrastructure failures can produce a
`BridgeRunError` without an exception value.

## Propagation Through Bridge

`MontyRuntime.execute` returns an `ExecutionHandle`. Its `events` stream
contains `BridgeEvent` values, and its `result` future completes with a
`MontyValue` or completes with the originating `MontyError`. A caller that
needs the error type catches the failure from `result`. A caller that renders
stream events reads `BridgeRunError.exception` when it is present.

## MontyValue Results and Errors

A successful execution completes with a `MontyValue`. An unsuccessful
execution completes with an error. A result object does not carry a separate
error field.

```text
runtime.execute(code).result
  │
  ├─ success → MontyValue
  │
  └─ failure → MontyError or an execution infrastructure error
```
