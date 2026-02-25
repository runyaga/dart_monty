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

Every `MontyPlatform` backend mixes in `MontyStateMixin` (from
`dart_monty_platform_interface`) which owns a three-state lifecycle:

```text
         start(pending)        resume(complete)
  ┌─────────────────────┐   ┌──────────────────┐
  │                     ▼   │                  ▼
IDLE ──── run() ──────► IDLE    ACTIVE ──────► IDLE
  │                             ▲    │
  │  start(pending/resolve)     │    │  resume(pending/resolve)
  └────────────────────────────►┘    └──► ACTIVE
  │                                       │
  │            dispose()                  │  dispose()
  └──────────────────────► DISPOSED ◄─────┘
```

### State Table

| State | Allowed operations | Forbidden |
|-------|--------------------|-----------|
| **idle** | `run()`, `start()`, `restore()`, `dispose()` | `resume*()`, `resolveFutures*()`, `snapshot()` |
| **active** | `resume()`, `resumeWithError()`, `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()`, `snapshot()`, `dispose()` | `run()`, `start()`, `restore()` |
| **disposed** | `dispose()` (idempotent no-op) | Everything else |

### Guard Methods

| Method | Throws when | Message |
|--------|------------|---------|
| `assertNotDisposed(method)` | disposed | `Cannot call $method() on a disposed $backendName` |
| `assertIdle(method)` | active | `Cannot call $method() while execution is active...` |
| `assertActive(method)` | not active | `Cannot call $method() when not in active state...` |

### Transition Methods

| Method | Effect |
|--------|--------|
| `markActive()` | Set state to active (after start/resume returns pending or resolve\_futures) |
| `markIdle()` | Set state to idle (after completion, error, or handle free) |
| `markDisposed()` | Set state to disposed (terminal) |

### `rejectInputs(inputs)`

Throws `UnsupportedError` if `inputs` is non-null and non-empty. All current
backends reject the `inputs` parameter — it exists for future variable
injection support.

### Backend-Specific Concerns

The mixin handles only state tracking. Backends remain responsible for:

- **Handle management** (FFI: `_handle` int, freed on complete/error/dispose)
- **Initialization** (WASM/Desktop: `initialize()` + `_ensureInitialized()`)
- **Bindings cleanup** (each backend calls its own `_bindings.dispose()`/`free()`)

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

**Definition:** For any given Python code string, all backends (FFI, Desktop,
WASM) must produce identical `MontyResult` values and identical
`MontyProgress` state machine transitions. Exceptions must carry the same
`message`, `excType`, and structural `traceback` information.

**Verification mechanisms:**

- **Ladder fixtures** (`test/fixtures/python_ladder/`) — JSON test cases
  covering expressions, variables, control flow, functions, errors, external
  functions, kwargs, exception fields, async/futures, and scriptName. Each
  backend runs the full fixture set via `registerLadderTests()` from the
  shared test harness (`dart_monty_testing.dart`).
- **JSONL diff** (M3C) — Native and web ladder runners emit JSONL output
  for the same fixtures; `tool/test_cross_path_parity.sh` diffs the output
  to detect divergences.

**Known divergences:**

- **Resource usage on WASM:** `MontyResourceUsage` fields are synthetic
  zeros (`memoryBytesUsed: 0`, `timeElapsedMs: 0`, `stackDepthUsed: 0`)
  because the NAPI-RS layer does not expose the Rust `ResourceTracker`.
- **`timeElapsedMs` precision:** Native backends report wall-clock
  microsecond precision; WASM reports millisecond precision from
  `performance.now()`.
- **Snapshot portability:** Snapshots are not portable across architectures
  (ARM64, x86_64, WASM). Same-platform restore only.

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

**Contract test pattern:** Each backend validates the `MontyPlatform`
behavioral contract via shared ladder helpers from
`dart_monty_platform_interface/dart_monty_testing.dart`. Backend-specific
tests cover transport and bindings concerns (Isolate messaging, JS interop,
FFI memory management).

**Shared test harness** (Slice 5):

- `assertLadderResult()` — verifies `expected`, `expectedContains`, and
  `expectedSorted` fixture fields against actual result values.
- `assertPendingFields()` — verifies M7A `MontyPending` fields:
  `expectedFnName`, `expectedArgs`, `expectedKwargs`,
  `expectedCallIdNonZero`, `expectedMethodCall`.
- `assertExceptionFields()` — verifies M7A `MontyException` fields:
  `expectedExcType`, `expectedTracebackMinFrames`,
  `expectedTracebackFrameHasFilename`, `expectedErrorFilename`,
  `expectedTracebackFilename`.
- `registerLadderTests()` — loads fixtures, creates `group()`/`test()` per
  tier, handles `xfail`, dispatches to simple/error/iterative runners.

**Test categorization:**

| Category | Scope | Example |
|----------|-------|---------|
| **Unit** | Mock bindings, no native library | `monty_ffi_test.dart` with `MockNativeBindings` |
| **Integration** | Real native library, single operations | `smoke_test.dart` — `run("1+1")` |
| **Ladder** | Fixture-driven parity across all tiers | `python_ladder_test.dart` via `registerLadderTests` |

Backend ladder tests are ~15-20 lines each: create a platform instance,
call `registerLadderTests()`, done. All assertion logic lives in the shared
harness.

---

## Testing Utilities

**Test barrel:** `dart_monty_testing.dart` exports `MockMontyPlatform` — the
platform-level mock for consumer packages. It is intentionally excluded from
the main `dart_monty_platform_interface.dart` barrel so production code never
depends on test infrastructure.

**Mock strategy:** All mocks are hand-rolled (no mocktail/mockito). Each mock
extends the real abstract class it replaces and follows a consistent pattern:

- **Configurable returns** — set fields like `runResult`, `snapshotData`,
  or `enqueueProgress()` before calling the method under test.
- **Invocation tracking** — lists such as `runCodes`, `startInputsList`,
  `resumeReturnValues` record every call in order.
- **Convenience getters** — `lastRunCode`, `lastStartInputs`, etc. for
  single-call assertions.

**Per-backend mocks** (`MockNativeBindings`, `MockWasmBindings`,
`MockDesktopBindings`) follow the same pattern at the bindings layer. Each
extends its package's abstract `*Bindings` class, providing configurable
return values (`next*` fields) and call-count tracking (`*Calls` lists).
Multi-step flows use a FIFO queue (`enqueueProgress`) so tests can script
`start → resume → complete` sequences.

---

## Native Crate Architecture

> *Filled by Slice 8: Rust Crate Consolidation*

<!-- Document the handle lifecycle (create -> run/start -> resume -> free),
     the FFI boundary contract (JSON in, JSON out, error via out-parameter),
     the tracker abstraction (Limited vs NoLimit), and the PrintWriter
     drain pattern. -->
