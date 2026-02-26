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
| **active** | `resume()`, `resumeWithError()`, `resumeAsFuture()`, `resolveFutures()`, `snapshot()`, `dispose()` | `run()`, `start()`, `restore()` |
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

**FFI (native path):**

- **Dart → Rust strings:** Dart allocates via `toNativeUtf8()`, passes the
  pointer to the C function, and frees in a `finally` block via
  `calloc.free()`. Rust reads (does not free) the pointer.
- **Rust → Dart strings:** Rust allocates via `CString::into_raw()`. Dart
  reads the pointer with `_readAndFreeString()`, which converts to a Dart
  `String` and then calls `monty_string_free()` to let Rust reclaim it.
- **Snapshots:** `monty_snapshot()` returns a Rust-allocated buffer and
  length. Dart copies into a `Uint8List` immediately, then calls
  `monty_bytes_free()` to release the Rust buffer. For restore, Dart
  allocates a native buffer via `calloc`, copies the `Uint8List` in, and
  frees after the call returns.
- **Handles:** `monty_create()` returns an opaque `Pointer<MontyHandle>`.
  Dart stores the `.address` as an `int`. `monty_free()` must be called
  exactly once per handle (called on complete, error, or dispose).

**Web (WASM path):**

- No shared memory. All data crosses via structured clone through
  `postMessage()` between main thread and Worker.
- Snapshots use base64 encoding: Worker converts `Uint8Array` → base64
  string via `btoa()`; Dart decodes base64 → `Uint8List`.
- The Worker holds the only reference to `MontySnapshot` and `Monty`
  objects; dispose clears them to `null`.

---

## Error Surface and Recovery Semantics

**Error categories:**

| Category | Source | Dart type |
|----------|--------|-----------|
| Python exception | User code (`raise`, syntax error, runtime error) | `MontyException` |
| Rust panic | Bug in monty crate (should not occur) | `StateError` (via null return or out-param) |
| FFI null return | `monty_create`/`monty_snapshot` returns null | `StateError` |
| State violation | Calling `run()` while active, `resume()` while idle | `StateError` |
| Isolate death | Background Isolate crashes or exits unexpectedly | `MontyException` (via `_failAllPending`) |
| Worker error | WASM Worker postMessage error or exception | `MontyException` (via `formatError`) |

**Propagation paths:**

- **Native (FFI):** The C API uses an `out_error` parameter for error
  strings. `NativeBindingsFfi` reads it with `_readAndFreeString()` and
  throws `StateError`. For progress errors (`MONTY_PROGRESS_ERROR` tag),
  the result JSON is read from `monty_complete_result_json()` and decoded
  into a `MontyException` with traceback frames.
- **Desktop (Isolate):** The background Isolate catches `MontyException`
  and wraps it in `_ErrorResponse`; other exceptions become
  `_GenericErrorResponse`. The main Isolate's `_send()` method rethrows
  accordingly.
- **Web (Worker):** `formatError()` in `worker_src.js` normalizes
  `MontyException`, `MontyTypingError`, and unknown errors into a
  `{ ok: false, error, errorType, excType?, traceback? }` message posted
  back to the main thread.

**`_failAllPending` semantics:** When `DesktopBindingsIsolate.dispose()`
is called or the Isolate exits unexpectedly, `_failAllPending()` copies
the pending completer map, clears it, and completes every outstanding
future with a `MontyException`. This prevents callers from hanging on
futures that will never receive a response.

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

- **Resource usage on WASM:** `memoryBytesUsed` and `stackDepthUsed` are
  zero because the NAPI-RS layer does not expose the Rust `ResourceTracker`.
  `timeElapsedMs` is measured on the Dart side via `Stopwatch` wrapping
  each bindings call — it reflects wall-clock time including Worker
  round-trip overhead.
- **`timeElapsedMs` precision:** Native backends report Rust-side wall-clock
  time; WASM reports Dart-side wall-clock time. Browser timing mitigations
  may clamp precision.
- **Snapshot portability:** Snapshots are not portable across architectures
  (ARM64, x86_64, WASM). Same-platform restore only.

---

## Execution Paths — Web

`DartMontyWeb` exists solely to satisfy Flutter's federated plugin convention.
It contains no logic — `registerWith()` sets `MontyPlatform.instance` to a
`MontyWasm` instance, and all subsequent calls go through `MontyWasm` directly:

```text
Flutter app
  → DartMontyWeb.registerWith()     (one-time, sets MontyPlatform.instance)
  → MontyWasm                       (extends MontyPlatform, owns state machine)
    → WasmBindingsJs                (dart:js_interop bridge to monty_glue.js)
      → monty_glue.js               (main-thread ↔ Worker postMessage relay)
        → Web Worker                (imports @pydantic/monty-wasm32-wasi)
          → @pydantic/monty WASM    (sandboxed Python interpreter)
```

**Why a Worker?** Chrome's synchronous `WebAssembly.compile()` limit is 8 MB.
The monty WASM module exceeds this, so it must be compiled inside a Worker
where the limit does not apply (async compile via `WebAssembly.compileStreaming`).

**COOP/COEP requirements:** The web server must set `Cross-Origin-Opener-Policy:
same-origin` and `Cross-Origin-Embedder-Policy: require-corp` headers. These
are required for `SharedArrayBuffer`, which the Worker uses for synchronous
communication with the main thread.

**Worker lifecycle:** The Worker is created lazily on the first `MontyWasm`
method call (`init()`). It persists for the lifetime of the `MontyWasm`
instance and is terminated on `dispose()`. All method calls are serialized
through the Worker's `postMessage` channel — there is no concurrent execution
within a single `MontyWasm` instance.

---

## Execution Paths — Native

```text
Flutter app
  → DartMontyDesktop.registerWith()    # Flutter plugin registration
    → MontyDesktop                     # MontyPlatform impl + MontyStateMixin
      → DesktopBindingsIsolate         # Isolate bridge
        → Isolate (same-group)         # Background thread
          → MontyFfi                   # MontyPlatform impl (pure Dart, no Flutter)
            → NativeBindingsFfi        # dart:ffi calls
              → libdart_monty_native   # Rust shared library (.dylib/.so/.dll)
                → monty (Rust crate)   # Sandboxed Python interpreter
```

**Why an Isolate:** FFI calls into the Monty Rust crate are synchronous
and can block for hundreds of milliseconds (compilation, execution with
limits). Running them on a background Isolate keeps the Flutter UI thread
responsive.

**Isolate protocol:** `DesktopBindingsIsolate` spawns a same-group Isolate
via `Isolate.spawn()`. Communication uses sealed `_Request`/`_Response`
classes sent directly through `SendPort` — no JSON encoding needed for
same-group isolates. Each request carries a unique `id`; the main thread
keeps a `Map<int, Completer<_Response>>` to match responses to callers.

**Library loading:** `NativeBindingsFfi` loads the native library via
`DynamicLibrary.open()` on desktop platforms (macOS, Linux, Windows). On
iOS, symbols are statically linked into the main executable and loaded
via `DynamicLibrary.process()` instead. An optional `libraryPath`
parameter overrides the default resolution for integration tests where
`DYLD_LIBRARY_PATH` may not propagate to spawned Isolates.

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
