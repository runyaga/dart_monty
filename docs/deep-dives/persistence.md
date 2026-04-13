# State Persistence Engine

One of the most powerful features of `AgentSession` is its ability to provide stateful Python execution without requiring a long-running interpreter instance. This "Virtual REPL" behavior is powered by the State Persistence Engine.

## The Problem: Ephemeral Interpreters

In many environments (especially WASM or highly-concurrent FFI), keeping a Python interpreter alive indefinitely is expensive or risky. However, agents need to define variables in one turn (`x = 42`) and use them in the next (`print(x)`).

`AgentSession` solves this by serializing the Python global state into Dart between every call.

## The Lifecycle of an `execute()` Call

When you call `session.execute(code)`, the persistence engine performs three hidden steps:

### 1. The Preamble (`__restore_state__`)

Before your code runs, the engine injects a restoration preamble. This preamble calls an internal `InfraCall` to retrieve the current state from Dart and inject it into Python's `globals()`.

```python
# Injected Preamble
__d = __restore_state__()
x = __d["x"]
y = __d["y"]
```

### 2. User Code Execution

Your code runs in the context of these pre-defined variables.

### 3. The Epilogue (`__persist_state__`)

After your code finishes, the engine injects an epilogue to capture any new or modified variables. It uses an internal `InfraCall` to send these variables back to Dart.

```python
# Injected Epilogue
__d2 = {"x": x, "y": y, "new_var": new_var}
__persist_state__(__d2)
```

## `code_capture` and AST Analysis

To make the epilogue efficient, `dart_monty` doesn't just "dump" everything. It uses a Dart-based AST analyzer (`code_capture`) to identify **assignment targets** in your script.

- If your script contains `a = 10`, the analyzer adds `a` to the capture list.
- If your script contains `b[0] = 1`, the analyzer adds `b` to the capture list.
- If your script is just a read-only expression like `x + 1`, the analyzer skips the capture logic for that turn.

## Capturing the "Result"

REPLs usually return the value of the last expression. The persistence engine handles this by identifying the last statement in your code. If it's an expression, it wraps it to capture the value in a special hidden variable (`__r`) before the epilogue runs.

```dart
// Original:
x = 1
x + 5

// Transformed for Result Capture:
x = 1
__r = x + 5
```

## Serialization Limits

The engine can persist anything that can be represented as structured data (JSON-compatible).

- **Supported**: Integers, Floats, Strings, Booleans, Lists, Dicts, and Nested Structures.
- **Not Supported**: Native Rust pointers, Python function objects (closures), class definitions (unless using a native REPL), and open file handles.

> **Note**: For true persistence of functions and classes, use `MontyRepl` or `ReplSession`, which maintains a native Rust heap instead of serializing to Dart.
