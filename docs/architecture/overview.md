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
dart_monty                           (single package — Monty() + conditional imports)
  │  Monty class delegates to createPlatformMonty() + OsProvider support:
  │    if (dart.library.ffi)           → MontyFfi()
  │    if (dart.library.js_interop)    → MontyWasm()
  │
  ├── lib/src/platform/               (abstract contract, pure Dart)
  │     ├── MontyPlatform              (abstract class)
  │     ├── BaseMontyPlatform          (shared logic: run/start/resume/dispose)
  │     ├── MontyCoreBindings          (unified bindings contract)
  │     ├── MontyStateMixin            (shared state machine lifecycle)
  │     ├── MontySnapshotCapable       (capability: snapshot/restore)
  │     ├── MontyFutureCapable         (capability: resumeAsFuture/resolveFutures)
  │     ├── MontySession               (stateful sessions — persists globals)
  │     ├── MontyProgress              (sealed: Pending | Complete | ResolveFutures | OsCall)
  │     └── MontyResult, MontyException, MontyStackFrame, ...
  │
  ├── lib/src/ffi/                     (pure Dart, no Flutter)
  │     ├── NativeBindings             (abstract) → NativeBindingsFfi (dart:ffi)
  │     ├── FfiCoreBindings            (implements MontyCoreBindings)
  │     ├── MontyFfi                   (extends BaseMontyPlatform)
  │     │     implements MontySnapshotCapable, MontyFutureCapable
  │     ├── MontyNative                (Isolate-based wrapper around MontyFfi)
  │     │     implements MontySnapshotCapable, MontyFutureCapable
  │     └── NativeLibraryLoader
  │
  ├── lib/src/wasm/                    (pure Dart, dart:js_interop)
  │     ├── WasmBindings               (abstract) → WasmBindingsJs (JS bridge)
  │     ├── WasmCoreBindings           (implements MontyCoreBindings)
  │     ├── MontyWasm                  (extends BaseMontyPlatform)
  │     │     implements MontySnapshotCapable
  │     └── js/                        (bridge.js + worker_src.js)
  │
  ├── lib/src/bridge/                  (high-level coordination)
  │     ├── AgentSession               (Facade: Bridge + Persistence + Registry)
  │     ├── MontyBridge                (Tool dispatch and event streaming)
  │     ├── MontyPlugin                (Abstract base for tool bundles)
  │     └── PluginRegistry             (Injection, OS composition, prompt generation)
  │
  └── lib/src/repl/                    (REPL: native heap persistence)
        ├── MontyRepl                  (Native Rust-backed REPL)
        └── ReplSession                (REPL + Plugins + Events)
```

## Platform Support Matrix

| Platform | Module | Status | Library |
|----------|--------|--------|---------|
| macOS | lib/src/ffi/ | Supported | `.dylib` |
| Linux | lib/src/ffi/ | Supported | `.so` |
| Web | lib/src/wasm/ | Supported | WASM via Worker |
| iOS | lib/src/ffi/ | Planned (M9) | `.a` static |
| Android | lib/src/ffi/ | Planned (M9) | `.so` via NDK |
| Windows | lib/src/ffi/ | Planned (M9) | `.dll` via MSVC |

## Choosing the Right API

| Use case | API | Example |
|----------|-----|---------|
| **Standard Agents** | `AgentSession` | `final s = AgentSession(); await s.execute('x=1');` |
| Native function/class persistence | `ReplSession` | `final s = ReplSession(); await s.run('def f():...');` |
| Host functions (no persistence) | `MontyBridge` | `bridge.register(...); bridge.execute(code)` |
| Simple one-shot scripts | `Monty.run()` | `await Monty.run('2+2')` |
| One-shot (no instance) | `Monty.exec()` | `await Monty.exec('2+2')` |
| Custom OS virtualization | `Monty(os: ...)` | See OsCall section |

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
- **`MontyPlugin` / `PluginRegistry`** -- pre-built tool bundles
  (e.g., `SandboxPlugin`, `MessageBusPlugin`) that group related functions
  under a namespace.
- **`BridgeEvent` stream** -- `bridge.execute()` returns a
  `Stream<BridgeEvent>` providing real-time observability into tool calls,
  text output, and lifecycle events.
- **`OsProvider`** -- transparent OS-level interception (filesystem, env,
  time) that Python does not know about. Works alongside explicit tools:
  `OsProvider` handles the "OS" side, plugins handle the "tool" side.

For a complete example, see the "LLM Tool Calling" section in the
[README](../README.md). For the OsProvider layer, see
[oscall-vfs.md](../deep-dives/oscall-vfs.md).

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

- [Trusted Grounding](../deep-dives/grounding.md) — The "Air Gap" security model and call attribution.
- [State Persistence](../deep-dives/persistence.md) — How AgentSession serializes Python state.
- [Reactive Signals](../deep-dives/signals.md) — Observing interpreter state with signals_core.
- [Security & Guardrails](../deep-dives/security.md) — Memory limits, stack depth, and timeouts.
- [Event Loop](../deep-dives/event-loop.md) — Cooperative multitasking via EventLoopPlugin.
- [OsCall / VFS Layer](../deep-dives/oscall-vfs.md) — Handler hierarchy and call flow.
- [Error Hierarchy](../deep-dives/error-hierarchy.md) — Sealed types and propagation.
- [Internals](../reference/internals.md) — Platform contracts and cross-language memory.
