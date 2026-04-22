# dart_monty Architecture

## Quick Orientation

dart_monty is a pure Dart package that exposes the Monty sandboxed Python
interpreter to Dart and Flutter applications. It wraps pydantic's `monty`
Rust crate via two execution paths: native (FFI to a shared library) and
web (JS interop to a WASM module running in a Web Worker). `Monty()`
is a high-level facade that selects the backend at compile time and
optionally dispatches OS calls (pathlib, os, datetime) through a
configurable handler. `Monty` no longer implements `MontyPlatform` — it
is a facade class, not a platform implementation. No Flutter required.

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
  │     ├── BaseMontyPlatform          (shared logic: run/start/resume/dispose)
  │     ├── MontyCoreBindings          (unified bindings contract)
  │     ├── MontyStateMixin            (shared state machine lifecycle)
  │     ├── MontySnapshotCapable       (capability: snapshot/restore)
  │     ├── MontyFutureCapable         (capability: resumeAsFuture/resolveFutures)
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
| Simple script evaluation | `Monty.exec()` | `await Monty.exec('2+2')` |
| Multiple runs, same interpreter | `Monty()` + `.run()` | `monty.run(code1); monty.run(code2)` |
| Stateful session (persist variables) | `MontySession` | `session.run('x=1'); session.run('x+1')` |
| Host functions + extensions | `MontyBridge` | `bridge.register(...); bridge.execute(code)` |
| LLM tool calling | `MontyBridge` + `bridge.schemas` | Register tools, feed schemas to LLM, execute generated code |
| Custom filesystem/env | `Monty(os: ...)` | See OsCall section |

## Tool Calling & LLM Integration

`MontyBridge` serves two audiences simultaneously:

1. **Python side** -- host functions are callable from sandboxed Python by
   name (e.g., `search("query")`).
2. **LLM side** -- the same functions are advertised as tool schemas
   (`HostFunctionSchema`) that LLMs use to generate Python code.

This dual-audience pattern means you register a tool once and get both a
callable Python function and an LLM-compatible tool definition.

### Execution Flow

```text
LLM sees tool schemas (bridge.schemas)
  -> LLM generates Python code calling those tools
    -> MontyBridge executes the Python in sandbox
      -> Python calls search("dart monty")
        -> Bridge yields MontyPending
          -> Bridge dispatches to HostFunction handler (Dart code)
            -> Result sent back to Python via resume()
              -> Python continues with the result
```

### Key Components

- **`HostFunctionSchema`** -- declares name, description, and parameters.
  Feed `bridge.schemas` directly to an LLM as tool definitions.
- **`HostFunction`** -- pairs a schema with a Dart handler that executes
  when Python calls the function.
- **`MontyExtension` / `ExtensionCoordinator`** -- pre-built tool bundles
  (e.g., `SandboxExtension`, `MessageBusExtension`) that group related functions
  under a namespace.
- **`BridgeEvent` stream** -- `bridge.execute()` returns a
  `Stream<BridgeEvent>` providing real-time observability into tool calls,
  text output, and lifecycle events.
- **`OsCallHandler`** -- transparent OS-level interception (filesystem, env,
  time) that Python does not know about. Works alongside explicit tools:
  `OsCallHandler` handles the "OS" side, extensions handle the "tool" side.

For a complete example, see the "LLM Tool Calling" section in the
[README](../README.md). For the OsCallHandler layer, see
[oscall-vfs.md](oscall-vfs.md).

## JSON Contract Reference

All data crosses the FFI/WASM boundary as JSON with snake_case keys. Dart
`fromJson` factories match these keys exactly.

| Dart type | JSON shape |
|-----------|-----------|
| `MontyResult` | `{ "value": ..., "error": {...}?, "usage": {...}, "print_output": "..."? }` |
| `MontyException` | `{ "message": "...", "filename"?, "line_number"?, "column_number"?, "source_code"? }` |
| `MontyResourceUsage` | `{ "memory_bytes_used": N, "time_elapsed_ms": N, "stack_depth_used": N }` |

Iterative execution uses C enum return tags (`MontyProgressTag`) plus accessor
functions — Dart constructs `MontyPending`/`MontyComplete` from these accessors,
not from a single JSON blob.

## Detailed Documentation

- [OsCall / VFS Layer](../deep-dives/oscall-vfs.md) — Handler hierarchy, platform defaults,
  call flow diagram, exception contract.
- [Error Hierarchy](../deep-dives/error-hierarchy.md) — Sealed types, type relationships,
  source-to-type mapping, propagation through boundaries.
- [Native Crate Architecture](../reference/native-crate.md) — Handle lifecycle, FFI boundary,
  tracker abstraction, PrintWriter drain.
- [Internals](../reference/internals.md) — BaseMontyPlatform/MontyCoreBindings, capability
  interfaces, MontySession, state machine contract, cross-language memory
  contracts, execution paths, cross-backend parity, testing strategy.
