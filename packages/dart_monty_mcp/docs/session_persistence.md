# Session Persistence

Persistent sessions let Python variables survive across separate
`monty_session_exec` calls. State is captured by serializing all global
variables to JSON after each execution completes, then restoring them
before the next call.

## What persists across calls

- Simple values: `int`, `float`, `str`, `bool`, `None`
- Container values: `list`, `dict` (with simple values inside)

## What does NOT persist

- Function definitions (must redefine in each exec call)
- Class instances
- Nested containers with non-serializable values

## In-place mutation caveat

> **Warning:** Because state is serialized to JSON and restored as new
> objects, in-place mutations and augmented assignments do **not** work
> across separate `monty_session_exec` calls.
>
> - **Don't:** `my_list.append(1)` or `x += 5`
> - **Do:** `my_list = my_list + [1]` or `x = x + 5`
>
> Within a *single* `monty_session_exec` call, in-place operations work
> normally. The limitation only applies across calls.

## Stateless execution

`monty_run` has no persistence at all. Each call creates a fresh
interpreter and disposes it when done. Use `monty_run` for one-shot
calculations and `monty_session_exec` when you need state.

## Session lifecycle

```text
monty_session_create(id: "calc")
  |
  v
monty_session_exec(session_id: "calc", code: "x = 42")
  |-- state restored from previous call (if any)
  |-- code executed
  |-- state persisted (simple values only)
  v
monty_session_exec(session_id: "calc", code: "x * 2")  -->  84
  |
  v
monty_session_destroy(session_id: "calc")
  |-- platform and session resources freed
```

## Programmatic example

```dart
import 'package:dart_monty_mcp/dart_monty_mcp.dart';
import 'package:mcp_dart/mcp_dart.dart';

// platformFactory creates a fresh interpreter per session
final server = MontyMcpServer(platformFactory: createPlatform);

server.sessionManager.createSession(id: 'calc');
final session = server.sessionManager.getSession('calc')!;

await session.execute('x = 42');
final result = await session.execute('x * 2');
final text = (result.content.first as TextContent).text;
// text == '84'

await server.sessionManager.destroySession('calc');
await server.dispose();
```

See [Handling Results and Errors](results_and_errors.md) for a full guide
on result and error extraction.
