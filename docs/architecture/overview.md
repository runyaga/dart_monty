# dart_monty Architecture

## Quick Orientation

dart_monty is a pure Dart package that exposes the Monty sandboxed Python
interpreter to Dart and Flutter applications. It wraps pydantic's `monty`
Rust crate via two execution paths: native (FFI to a shared library) and
web (JS interop to a WASM module running in a Web Worker).

`MontyRuntime` is the recommended high-level API for stateful sessions with
extensions and OS-level interception.

## Architecture Diagrams

### Diagram 1: High-Level Package Dependency

This diagram provides a simple, high-level overview of the main components and their dependencies, illustrating how the packages fit together.

```mermaid
graph TD
    subgraph User Application
        A[Dart/Flutter App]
    end

    subgraph dart_monty
        B(MontyRuntime API)
    end

    subgraph dart_monty_core
        C(Low-Level Engine)
    end

    subgraph Rust
        D{Monty Crate}
    end

    A --> B
    B --> C
    C --> D
```

### Diagram 2: API Layering & Abstraction

This diagram illustrates the separation of concerns and how the APIs are layered, from the user-facing runtime down to the platform-specific backends.

```mermaid
graph TD
    subgraph dart_monty [High-Level API]
        A(MontyRuntime)
        B(ExtensionCoordinator)
        C(PlatformBridge)
        D(OsCallHandler)
    end

    subgraph dart_monty_core [Low-Level Engine]
        E(MontyPlatform)
        F(MontyRepl)
        G[FFI Backend]
        H[WASM Backend]
    end

    A --> B & C
    B --> C
    C --> D & E
    E --> F
    F --> G & H
```

### Diagram 3: Execution Flow for a Tool Call

This diagram shows the sequence of events when a user calls `execute` and the Python code invokes a host function (a "tool").

```mermaid
sequenceDiagram
    actor User
    participant RT as MontyRuntime
    participant PB as PlatformBridge
    participant MR as MontyRepl (Core)
    participant HF as Host Function (Dart)

    User->>RT: execute("my_tool()")
    RT->>PB: execute("my_tool()")
    PB->>MR: feedRun("my_tool()")
    MR-->>PB: Yields (Pending Tool Call)
    PB->>HF: Invoke handler for "my_tool"
    HF-->>PB: Returns result
    PB->>MR: resume(result)
    MR-->>PB: Completes
    PB-->>RT: ExecutionHandle completes
    RT-->>User: Returns MontyResult
```

## Internal Module Structure

```text
dart_monty                           (high-level API package)
  │
  ├── lib/src/runtime/               (session management)
  │     ├── MontyRuntime              (high-level session facade)
  │     └── ExecutionHandle           (async execution control)
  │
  ├── lib/src/bridge/                (tool-calling layer)
  │     ├── PlatformBridge            (tool schema + dispatch logic)
  │     └── BridgeEvent               (streamable execution events)
  │
  ├── lib/src/extension/             (extension system)
  │     ├── MontyExtension            (abstract base)
  │     └── ExtensionCoordinator      (lifecycle and registration)
  │
  └── lib/src/os_call/               (VFS and OS-level interception)
        └── OsCallHandler             (operation interception logic)

dart_monty_core                      (low-level core engine package)
  │
  ├── lib/src/platform/               (abstract contract, pure Dart)
  │     ├── MontyPlatform              (abstract class)
  │     ├── MontyCoreBindings          (unified bindings contract)
  │     └── MontyResult, MontyException, MontyStackFrame, ...
  │
  ├── lib/src/repl/                   (stateful Python REPL)
  │     ├── MontyRepl                  (persistent Rust-backed REPL)
  │     └── ReplPlatform               (adapts MontyRepl to MontyPlatform)
  │
  ├── lib/src/ffi/                    (native FFI backend)
  │     └── MontyFfi                   (FFI implementation)
  │
  └── lib/src/wasm/                   (web WASM backend)
        └── MontyWasm                  (WASM implementation)
```

## Platform Support Matrix

| Platform | Module | Status | Library |
|----------|--------|--------|---------|
| macOS | dart_monty_core (FFI) | Supported | `.dylib` |
| Linux | dart_monty_core (FFI) | Supported | `.so` |
| Web | dart_monty_core (WASM) | Supported | WASM via Worker |
| iOS | dart_monty_core (FFI) | Planned (M9) | `.a` static |
| Android | dart_monty_core (FFI) | Planned (M9) | `.so` via NDK |
| Windows | dart_monty_core (FFI) | Planned (M9) | `.dll` via MSVC |

## Choosing the Right API

| Use case | API | Example |
|----------|-----|---------|
| Stateful session with tools | `MontyRuntime` | `final session = MontyRuntime(extensions: ...)` |
| Simple stateful evaluation | `MontyRepl` | `final repl = MontyRepl(); repl.feedRun('x=1')` |
| One-shot stateless evaluation | `Monty.exec()` | `await Monty.exec('2+2')` |

## Tool Calling & LLM Integration

The `MontyRuntime` and `PlatformBridge` serve two audiences simultaneously:

1. **Python side** -- host functions are callable from sandboxed Python by
   name (e.g., `search("query")`).
2. **LLM side** -- the same functions are advertised as tool schemas
   (`HostFunctionSchema`) that LLMs use to generate Python code.

This dual-audience pattern means you register a tool once and get both a
callable Python function and an LLM-compatible tool definition.

For the `OsCallHandler` layer, see [OsCall / VFS Layer](../deep-dives/oscall-vfs.md).
