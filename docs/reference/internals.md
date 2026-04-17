# Internals

This document covers the internal architecture of dart_monty: platform
abstractions, capability interfaces, session management, state machine
contracts, memory management, execution paths, cross-backend parity, and
testing infrastructure.

## BaseMontyPlatform and MontyCoreBindings

`BaseMontyPlatform` is the shared base class for `MontyFfi` and `MontyWasm`.
It extends `MontyPlatform`, mixes in `MontyStateMixin`, and implements the
common `run()`, `start()`, `resume()`, `resumeWithError()`, and `dispose()`
logic. All state guards, limits encoding, and result translation happen
once in `BaseMontyPlatform`.

`MontyCoreBindings` is the unified bindings contract that both backends
implement via adapter classes:

- `FfiCoreBindings` adapts `NativeBindings` (sync FFI) to `MontyCoreBindings`
- `WasmCoreBindings` adapts `WasmBindings` (async JS) to `MontyCoreBindings`

Intermediate result types (`CoreRunResult`, `CoreProgressResult`) carry
raw data from bindings. `BaseMontyPlatform` translates these into domain
types (`MontyResult`, `MontyProgress`).

`MontyNative` does not extend `BaseMontyPlatform` -- it extends
`MontyPlatform` directly with `MontyStateMixin`, wrapping
`NativeIsolateBindings` for Isolate-based execution.

## Capability Interfaces

Optional capabilities are exposed as separate interfaces rather than
`UnsupportedError` stubs on `MontyPlatform`:

| Interface | Methods | Implemented by |
|-----------|---------|----------------|
| `MontySnapshotCapable` | `snapshot()`, `restore()` | MontyFfi, MontyWasm, MontyNative |
| `MontyFutureCapable` | `resumeAsFuture()`, `resolveFutures()` | MontyFfi, MontyNative |

Consumers use `is` checks: `if (platform is MontyFutureCapable) { ... }`

## MontySession

`MontySession` wraps any `MontyPlatform` and persists Python globals across
multiple `run()` calls using snapshot/restore under the hood. It registers
internal external functions (`__restore_state__`, `__persist_state__`) to
transparently save and reload interpreter state between executions.

Key methods: `run()`, `start()`, `resume()`, `resumeWithError()`,
`clearState()`, `dispose()`. State is tracked via `MontySessionState`
(idle, active, disposed).

## State Machine Contract

Every `MontyPlatform` backend mixes in `MontyStateMixin` (from
`lib/src/platform/`) which owns a three-state lifecycle:

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
backends reject the `inputs` parameter -- it exists for future variable
injection support.

### Backend-Specific Concerns

The mixin handles only state tracking. Backends remain responsible for:

- **Handle management** (FFI: `_handle` int, freed on complete/error/dispose)
- **Initialization** (WASM/Native: `initialize()` + `_ensureInitialized()`)
- **Bindings cleanup** (each backend calls its own `_bindings.dispose()`/`free()`)

## Cross-Language Memory Contracts

**FFI (native path):**

- **Dart to Rust strings:** Dart allocates via `toNativeUtf8()`, passes the
  pointer to the C function, and frees in a `finally` block via
  `calloc.free()`. Rust reads (does not free) the pointer.
- **Rust to Dart strings:** Rust allocates via `CString::into_raw()`. Dart
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
- Snapshots use base64 encoding: Worker converts `Uint8Array` to base64
  string via `btoa()`; Dart decodes base64 to `Uint8List`.
- The Worker holds the only reference to `MontySnapshot` and `Monty`
  objects; dispose clears them to `null`.

## Execution Paths -- Web

```text
Dart app (compiled to JS)
  → Monty() → MontyWasm             (via conditional import, extends MontyPlatform)
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
through the Worker's `postMessage` channel -- there is no concurrent execution
within a single `MontyWasm` instance.

## Execution Paths -- Native

```text
Dart app
  → Monty() → MontyFfi               # via conditional import (dart.library.ffi)
    → NativeBindingsFfi              # dart:ffi calls
      → libdart_monty_native         # Rust shared library (.dylib/.so/.dll)
        → monty (Rust crate)         # Sandboxed Python interpreter
```

For Flutter apps or long-running executions, use `MontyNative` (from
`dart_monty_core`) which wraps `MontyFfi` in a background Isolate:

```text
Dart app
  → MontyNative                      # Isolate-based wrapper
    → NativeIsolateBindingsImpl      # Isolate bridge
      → Isolate (same-group)         # Background thread
        → MontyFfi                   # dart:ffi bindings
          → libdart_monty_native     # Rust shared library
```

**Why an Isolate:** FFI calls into the Monty Rust crate are synchronous
and can block for hundreds of milliseconds (compilation, execution with
limits). Running them on a background Isolate keeps the UI thread
responsive.

**Isolate protocol:** `NativeIsolateBindingsImpl` spawns a same-group Isolate
via `Isolate.spawn()`. Communication uses sealed `_Request`/`_Response`
classes sent directly through `SendPort` -- no JSON encoding needed for
same-group isolates. Each request carries a unique `id`; the main thread
keeps a `Map<int, Completer<_Response>>` to match responses to callers.

**Library loading:** `NativeBindingsFfi` loads the native library via
`DynamicLibrary.open()` on desktop platforms (macOS, Linux, Windows). On
iOS, symbols are statically linked into the main executable and loaded
via `DynamicLibrary.process()` instead. An optional `libraryPath`
parameter overrides the default resolution for integration tests where
`DYLD_LIBRARY_PATH` may not propagate to spawned Isolates.

## Cross-Backend Parity Guarantees

**Definition:** For any given Python code string, all backends (FFI, Native,
WASM) must produce identical `MontyResult` values and identical
`MontyProgress` state machine transitions. Exceptions must carry the same
`message`, `excType`, and structural `traceback` information.

**Verification mechanisms:**

- **Ladder fixtures** (`test/fixtures/python_ladder/`) -- JSON test cases
  covering expressions, variables, control flow, functions, errors, external
  functions, kwargs, exception fields, async/futures, and scriptName. Each
  backend runs the full fixture set via `registerLadderTests()` from the
  shared test harness (`dart_monty_testing.dart`).
- **JSONL diff** (M3C) -- Native and web ladder runners emit JSONL output
  for the same fixtures; `tool/test_cross_path_parity.sh` diffs the output
  to detect divergences.

**Known divergences:**

- **Resource usage on WASM:** `memoryBytesUsed` and `stackDepthUsed` are
  zero because the NAPI-RS layer does not expose the Rust `ResourceTracker`.
  `timeElapsedMs` is measured on the Dart side via `Stopwatch` wrapping
  each bindings call -- it reflects wall-clock time including Worker
  round-trip overhead.
- **`timeElapsedMs` precision:** Native backends report Rust-side wall-clock
  time; WASM reports Dart-side wall-clock time. Browser timing mitigations
  may clamp precision.
- **Snapshot portability:** Snapshots are not portable across architectures
  (ARM64, x86_64, WASM). Same-platform restore only.

## Testing Strategy

**Contract test pattern:** Each backend validates the `MontyPlatform`
behavioral contract via shared ladder helpers from
`package:dart_monty/dart_monty_testing.dart`. Backend-specific tests cover
transport and bindings concerns (Isolate messaging, JS interop, FFI memory
management).

**Shared test harness** (Slice 5):

- `assertLadderResult()` -- verifies `expected`, `expectedContains`, and
  `expectedSorted` fixture fields against actual result values.
- `assertPendingFields()` -- verifies M7A `MontyPending` fields:
  `expectedFnName`, `expectedArgs`, `expectedKwargs`,
  `expectedCallIdNonZero`, `expectedMethodCall`.
- `assertExceptionFields()` -- verifies M7A `MontyException` fields:
  `expectedExcType`, `expectedTracebackMinFrames`,
  `expectedTracebackFrameHasFilename`, `expectedErrorFilename`,
  `expectedTracebackFilename`.
- `registerLadderTests()` -- loads fixtures, creates `group()`/`test()` per
  tier, handles `xfail`, dispatches to simple/error/iterative runners.

**Test categorization:**

| Category | Scope | Example |
|----------|-------|---------|
| **Unit** | Mock bindings, no native library | `monty_ffi_test.dart` with `MockNativeBindings` |
| **Integration** | Real native library, single operations | `smoke_test.dart` -- `run("1+1")` |
| **Ladder** | Fixture-driven parity across all tiers | `python_ladder_test.dart` via `registerLadderTests` |

Backend ladder tests are ~15-20 lines each: create a platform instance,
call `registerLadderTests()`, done. All assertion logic lives in the shared
harness.

## Testing Utilities

**Test barrel:** `dart_monty_testing.dart` exports `MockMontyPlatform` -- the
platform-level mock for consumers. It is intentionally excluded from the
main `package:dart_monty/dart_monty.dart` barrel so production code never
depends on test infrastructure.

**Mock strategy:** All mocks are hand-rolled (no mocktail/mockito). Each mock
extends the real abstract class it replaces and follows a consistent pattern:

- **Configurable returns** -- set fields like `runResult`, `snapshotData`,
  or `enqueueProgress()` before calling the method under test.
- **Invocation tracking** -- lists such as `runCodes`, `startInputsList`,
  `resumeReturnValues` record every call in order.
- **Convenience getters** -- `lastRunCode`, `lastStartInputs`, etc. for
  single-call assertions.

**Per-backend mocks** (`MockNativeBindings`, `MockWasmBindings`,
`MockNativeIsolateBindings`) follow the same pattern at the bindings layer. Each
extends its package's abstract `*Bindings` class, providing configurable
return values (`next*` fields) and call-count tracking (`*Calls` lists).
Multi-step flows use a FIFO queue (`enqueueProgress`) so tests can script
`start -> resume -> complete` sequences.
