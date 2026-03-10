# Session Persistence

Persistent sessions use JSON serialization to save and restore Python state
between calls to `monty_session_exec`.

## What persists across calls

- Simple values: `int`, `float`, `str`, `bool`, `None`
- Container values: `list`, `dict` (with simple values inside)

## What does NOT persist

- Function definitions (must redefine in each exec call)
- Class instances
- In-place mutations (`data['key'] = val` across calls)
- Augmented assignments (`x += 5` -- use `x = x + 5` instead)

## Stateless execution

`monty_run` has no persistence at all. Each call creates a fresh
interpreter and disposes it when done.

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
