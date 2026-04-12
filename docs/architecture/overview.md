# Architecture Overview

dart_monty is a pure Dart package that exposes the Monty sandboxed Python interpreter to Dart and Flutter. It selects either a native (FFI) or web (WASM) backend at compile time.

## Module Structure

```text
dart_monty (single package)
├── lib/src/platform/    Core types: MontyResult, MontyValue, MontySession
├── lib/src/ffi/         Native FFI backend (dart:ffi)
├── lib/src/wasm/        Web WASM backend (dart:js_interop + Worker)
├── lib/src/bridge/      Plugin dispatch, middleware, and event loop
└── native/              Rust C API crate (.dylib/.so/.dll + .wasm)
```

## The Execution Bridge

The `MontyBridge` manages the dispatch loop between Dart and Python. It is the primary layer for building applications.

1. **Dart** calls `bridge.execute(code)`.
2. **Python** runs until it calls a host function or finishes.
3. **Bridge** intercepts host calls, executes the Dart handler, and resumes Python with the result.
4. **Middleware** can be inserted into this chain to provide logging, grounding, or security policies.

## Sandbox and Isolation

`SandboxPlugin` allows Python to spawn isolated child interpreters.
- **Native**: Children run in fresh Rust interpreter instances.
- **Web**: Children run in independent Web Workers for true memory isolation.

## Errors and Exceptions

Errors are organized into a sealed hierarchy:
- **`MontyException`**: Python-side exceptions (syntax errors, logic errors).
- **`OsCallException`**: Errors during OS-level interception (file not found, etc).
- **`MontyResourceException`**: Limits exceeded (memory, time, stack depth).

## Filesystem and OS Interception

The `OsProvider` layer transparently intercepts Python's `pathlib`, `os`, and `datetime` calls. You can configure:
- **`MemoryFsProvider`**: An ephemeral, in-memory virtual filesystem.
- **`SandboxedFsProvider`**: Restricts native filesystem access to a specific directory.
- **`ReadOnlyFsProvider`**: Blocks all write operations.
