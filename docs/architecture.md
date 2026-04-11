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
  └── lib/src/wasm/                    (pure Dart, dart:js_interop)
        ├── WasmBindings               (abstract) → WasmBindingsJs (JS bridge)
        ├── WasmCoreBindings           (implements MontyCoreBindings)
        ├── MontyWasm                  (extends BaseMontyPlatform)
        │     implements MontySnapshotCapable
        └── js/                        (bridge.js + worker_src.js)
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
| Simple script evaluation | `Monty.exec()` | `await Monty.exec('2+2')` |
| Multiple runs, same interpreter | `Monty()` + `.run()` | `monty.run(code1); monty.run(code2)` |
| Stateful session (persist variables) | `MontySession` | `session.run('x=1'); session.run('x+1')` |
| Host functions + plugins | `DefaultMontyBridge` | `bridge.register(...); bridge.execute(code)` |
| Custom filesystem/env | `Monty(os: ...)` | See OsCall section |

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

- [OsCall / VFS Layer](oscall-vfs.md) — Handler hierarchy, platform defaults,
  call flow diagram, exception contract.
- [Error Hierarchy](error-hierarchy.md) — Sealed types, type relationships,
  source-to-type mapping, propagation through boundaries.
- [Native Crate Architecture](native-crate.md) — Handle lifecycle, FFI boundary,
  tracker abstraction, PrintWriter drain.
- [Internals](internals.md) — BaseMontyPlatform/MontyCoreBindings, capability
  interfaces, MontySession, state machine contract, cross-language memory
  contracts, execution paths, cross-backend parity, testing strategy.
