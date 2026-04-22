# Internals

This document covers the internal architecture of dart_monty: platform
abstractions, the bridge and extension system, session management, state machines,
and execution paths.

## Core Architecture

The system is split into two main packages:
- **`dart_monty_core`**: The low-level engine. It provides the abstract `MontyPlatform`, the stateful `MontyRepl`, and the concrete FFI and WASM backend implementations (`MontyFfi`, `MontyWasm`).
- **`dart_monty`**: The high-level API. It provides the `MontyRuntime` for session management, the `PlatformBridge` for tool-calling, and the `ExtensionCoordinator` for managing extensions.

## Bridge & Extension System

- **`PlatformBridge`**: The central hub that connects a `MontyPlatform` backend to the tool system. It manages the execution loop, dispatches tool calls to host functions, and streams `BridgeEvent`s.
- **`ExtensionCoordinator`**: Manages the lifecycle of all registered extensions. It handles registration, validation, attachment to the bridge, and disposal.
- **`MontyExtension`**: The base class for creating tool bundles. Key features include:
    - **`osContribution`**: A declarative way for an extension to intercept OS-level calls (like `pathlib`).
    - **`childPolicy`**: An enum (`clone`, `inherit`, `exclude`) that defines how the extension behaves when a `SandboxExtension` creates a child interpreter.
    - **`onAttach` / `onDispose`**: Lifecycle hooks for managing resources.

## Session Management (`MontyRuntime`)

`MontyRuntime` is the primary, user-facing API. It encapsulates a `PlatformBridge`, an `ExtensionCoordinator`, and a `MontyRepl` instance to provide a stateful execution environment with tools.

- **Shared Mode (default)**: A single `MontyRepl` instance is used for all `execute` calls, so Python state (variables, functions) persists.
- **Sandbox Mode (`sandbox: true`)**: Each `execute` call gets a fresh, isolated `MontyRepl` instance, which is disposed of after the call completes. This is safer for concurrent operations or untrusted code.

## State Machine Contract

The `MontyRepl` in `dart_monty_core` manages the raw execution state (idle, active, disposed). The higher-level `MontyRuntime` builds on this to manage its own lifecycle, ensuring that resources like extensions and the bridge are correctly initialized and torn down.

## Execution Paths

### Web (WASM)
The `MontyWasm` backend communicates with a Web Worker. Critically, **COOP/COEP headers are no longer required**. The move to the `wasm32-wasip1` Rust target allows for a more streamlined setup. The `SandboxExtension` works by creating new, isolated REPL sessions within the *same* worker, identified by a unique `replId`, which is more efficient than spinning up new workers.

### Native (FFI)
The `MontyFfi` backend calls the Rust shared library (`.dylib`, `.so`, `.dll`) via `dart:ffi`. For UI applications, it's recommended to run this in a background isolate to prevent blocking the main thread, which `MontyRuntime` can handle.

## Cross-Language Memory Contracts

- **FFI (Native)**: Strings and bytes are passed as pointers. Dart is responsible for allocating and freeing memory for data it sends to Rust, and for freeing pointers returned from Rust using designated `_free` functions.
- **Web (WASM)**: All data is passed by value via `postMessage`, using the structured clone algorithm. There is no shared memory.
