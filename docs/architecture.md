# dart_monty Architecture

## Quick Orientation

dart_monty is a Flutter federated plugin that exposes the Monty sandboxed
Python interpreter to Dart and Flutter applications. It wraps pydantic's
`monty` Rust crate via two execution paths: native (FFI to a shared library)
and web (JS interop to a WASM module running in a Web Worker). A single
Flutter app automatically selects the correct backend at registration time.

## Package Dependency Graph

```text
dart_monty                         (app-facing API — thin re-export)
  ├── dart_monty_platform_interface  (abstract contract, pure Dart)
  │     ├── MontyPlatform            (abstract class, singleton)
  │     ├── MontyProgress            (sealed: Pending | Complete)
  │     ├── MontyResult, MontyException, MontyStackFrame, ...
  │     └── MontyStateMixin          (shared lifecycle — Slice 4)
  │
  ├── dart_monty_ffi                 (pure Dart, no Flutter)
  │     ├── NativeBindings           (abstract) → NativeBindingsFfi (dart:ffi)
  │     ├── MontyFfi                 (implements MontyPlatform)
  │     └── NativeLibraryLoader
  │
  ├── dart_monty_wasm                (pure Dart, dart:js_interop)
  │     ├── WasmBindings             (abstract) → WasmBindingsJs (JS bridge)
  │     ├── MontyWasm                (implements MontyPlatform)
  │     └── js/                      (bridge.js + worker_src.js)
  │
  ├── dart_monty_desktop             (Flutter plugin — macOS, Linux, future: iOS/Android/Windows)
  │     ├── DartMontyDesktop         (registration + ffiPlugin: true)
  │     ├── DesktopBindings          (abstract) → DesktopBindingsIsolate
  │     └── MontyDesktop             (implements MontyPlatform, Isolate offload)
  │
  └── dart_monty_web                 (Flutter plugin — web)
        └── DartMontyWeb             (registration shim, delegates to MontyWasm)
```

## Platform Support Matrix

| Platform | Package | Status | Library |
|----------|---------|--------|---------|
| macOS | dart_monty_desktop | Supported | `.dylib` |
| Linux | dart_monty_desktop | Supported | `.so` |
| Web | dart_monty_web | Supported | WASM via Worker |
| iOS | dart_monty_desktop | Planned (M9) | `.a` static |
| Android | dart_monty_desktop | Planned (M9) | `.so` via NDK |
| Windows | dart_monty_desktop | Planned (M9) | `.dll` via MSVC |

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

---

## State Machine Contract

> *Filled by Slice 4: State Machine Consolidation*

<!-- Document the lifecycle (idle -> active <-> pending -> idle | disposed),
     the invariants each guard enforces, the initialize() contract, and
     the MontyStateMixin interface. -->

---

## Cross-Language Memory Contracts

> *Filled by Slice 7: Desktop & WASM Refinement*

<!-- Document the FFI/WASM memory lifecycle: who allocates, who frees,
     what happens on a panic/exception, _readAndFreeString semantics,
     snapshot memory ownership. -->

---

## Error Surface and Recovery Semantics

> *Filled by Slice 7: Desktop & WASM Refinement*

<!-- Document error categories (Python exception, Rust panic, Dart StateError,
     Isolate failure), how each propagates through the stack, and the
     _failAllPending recovery path in Desktop. -->

---

## Cross-Backend Parity Guarantees

> *Filled by Slice 5: Shared Test Harness*

<!-- Document what "parity" means: identical MontyResult/MontyProgress for
     the same Python code across FFI, WASM, and Desktop backends. How it's
     verified (ladder fixtures, JSONL diff). Known divergences (synthetic
     resource usage on WASM, timeElapsedMs precision). -->

---

## Execution Paths — Web

> *Filled by Slice 6: Web Package Simplification*

<!-- Document the web execution path: DartMontyWeb -> MontyWasm -> JS bridge ->
     Worker -> @pydantic/monty WASM. Why DartMontyWeb exists (Flutter convention)
     and what it does NOT do. COOP/COEP requirements. Worker lifecycle. -->

---

## Execution Paths — Native

> *Filled by Slice 7: Desktop & WASM Refinement*

<!-- Document the native execution path: DartMontyDesktop -> Isolate ->
     MontyFfi -> dart:ffi -> libdart_monty_native -> Monty Rust. Library
     loading (DynamicLibrary.open vs .process for iOS). Isolate message
     passing protocol. -->

---

## Testing Strategy

> *Filled by Slice 5: Shared Test Harness*

<!-- Document the contract test pattern: each backend validates MontyPlatform
     behavioral contract via shared helpers, plus backend-specific tests for
     transport concerns. Test categorization: unit (mock bindings), integration
     (real library), ladder (fixture-driven parity). -->

---

## Testing Utilities

> *Filled by Slice 3: Mock & API Surface Cleanup*

<!-- Document what dart_monty_testing.dart exports, the mock strategy decision
     (hand-rolled vs mocktail), and how to write tests for new backends. -->

---

## Native Crate Architecture

> *Filled by Slice 8: Rust Crate Consolidation*

<!-- Document the handle lifecycle (create -> run/start -> resume -> free),
     the FFI boundary contract (JSON in, JSON out, error via out-parameter),
     the tracker abstraction (Limited vs NoLimit), and the PrintWriter
     drain pattern. -->
