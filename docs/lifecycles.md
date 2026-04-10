# Resource Lifecycle Audit

Inventories every resource allocated across dart_monty subsystems,
how each is freed, what happens on crash, and known gaps.

Last updated: 2026-04-10 (monty 0.0.10, post-OsCall + MontyValue)

---

## A. Rust FFI Layer (`native/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| `MontyHandle` (heap) | `monty_create` → `Box::into_raw` | `monty_free` → `Box::from_raw` | Dart FFI caller |
| `LIVE_HANDLES` entry | `monty_create` (lib.rs:91) | `monty_free` (lib.rs:130) | Static `HashSet` |
| C strings (error messages) | `to_c_string` (error.rs) | `monty_string_free` (lib.rs) | Dart FFI caller |
| Snapshot byte buffer | `monty_snapshot` (lib.rs) | `monty_bytes_free` (lib.rs) | Dart FFI caller |

### Crash Behavior

- **Panic during execution**: Caught by `catch_ffi_panic` (error.rs:13).
  Handle stays valid. Returns error tag. No leak.
- **`monty_free` never called**: Handle leaks permanently.
- **Double-free on `monty_free`**: Safe no-op — `LIVE_HANDLES.remove()`
  returns false on second call (lib.rs:130-132).

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| ~~A-1~~ | ~~Low~~ | RESOLVED | `LIVE_HANDLES` is a HashSet — entries properly removed on free. |
| ~~A-2~~ | ~~Critical~~ | RESOLVED | Double-free protection added via `LIVE_HANDLES` check before `Box::from_raw`. |

---

## B. Dart FFI Bindings (`packages/dart_monty_ffi/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| FFI handle (int address) | `FfiCoreBindings.run/start` | `_freeHandle` → `_bindings.free()` | `FfiCoreBindings` |
| Background isolate | `NativeIsolateBindingsImpl.init` | `dispose()`/`terminate()` → `Isolate.kill` | `NativeIsolateBindingsImpl` |
| `ReceivePort` | `init()` | `dispose()` → `.close()` | `NativeIsolateBindingsImpl` |
| Pending completers map | Per request | `_failAllPending` on dispose/crash | `NativeIsolateBindingsImpl` |

### Crash Behavior

- **`FfiCoreBindings.run()`**: `try/finally` always frees handle. Correct.
- **`FfiCoreBindings.start()` error**: `catch` frees handle. Correct.
- **Isolate dies unexpectedly**: `addOnExitListener` fires null message.
  `_failAllPending` completes all futures with errors.
- **`terminate()` timeout**: After 5s, increments `_zombieCount`. Warning
  emitted at threshold of 3. Handle may leak in killed isolate.

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| ~~B-1~~ | ~~Critical~~ | RESOLVED | Zombie tracking + diagnostic logging added. Handle leak is intentional safety choice. |
| B-3 | Safe | OK | `_freeHandle` nulls `_handle` before calling `free()`. Prevents double-free. |
| B-4 | Moderate | OPEN | `restoreSnapshot` does not free prior handle. Protected by state machine `assertIdle` but no defensive code. |

---

## C. Platform Interface (`packages/dart_monty_platform_interface/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| State machine (`_MontyState`) | Construction | N/A (enum, not heap) | `MontyStateMixin` |
| `MontySession._state` map | Construction | `clearState()`/`dispose()` | `MontySession` |

### Crash Behavior

- **`BaseMontyPlatform.run()`**: `markActive()` in try, `markIdle()` in finally. Correct.
- **`BaseMontyPlatform.resume()` error**: Catches, calls `markIdle()`, rethrows. State machine unblocked.
- **`dispose()` while active**: Calls `_bindings.dispose()` which frees
  handle. But a concurrent in-flight resume could race with the free.

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| C-3 | Moderate | OPEN | No "disposed while active" recovery. Concurrent resume and dispose could race on FFI handle. |

---

## D. WASM Bindings (`packages/dart_monty_wasm/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| JS Worker session | `WasmBindingsJs.createSession()` | `disposeSession()` | `WasmCoreBindings` |
| Session ID (String) | `createSession` | Nulled on dispose or panic | `WasmCoreBindings` |

### Crash Behavior

- **WASM panic/trap**: `_invalidateSession()` nulls `_sessionId`, throws
  `MontyPanicError`. Worker is dead; subsequent calls require new session.
- **Worker termination during in-flight call**: Pending `JSPromise.toDart`
  rejects. Error classified by string matching on `errorType`.

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| ~~D-1~~ | ~~Critical~~ | RESOLVED | `_invalidateSession()` called on panic — session properly invalidated. |
| D-2 | Moderate | OPEN | Error classification uses string matching (`'Panic'`, `'RuntimeError'`). Fragile if Worker error format changes. |

---

## E. Bridge Layer (`packages/dart_monty_bridge/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| `StreamController` per execute | `execute()` | `whenComplete` closure | `DefaultMontyBridge` |
| `_pendingFutures` map | Per async dispatch | `finally` block in `_run` | `DefaultMontyBridge` |
| `EventLoopBridge._eventLoopController` | Construction | `dispose()` | `EventLoopBridge` |
| `EventLoopBridge._pendingCompleter` | `wait_for_event` call | Completed on event or dispose | `EventLoopBridge` |
| `SandboxPlugin._children` map | `sandbox_spawn` | `sandbox_free` or `onDispose` | `SandboxPlugin` |
| Child `MontyPlatform` | `sandbox_spawn` | `_ChildHandle.tearDown()` or `onDone` | `SandboxPlugin` |
| Child `DefaultMontyBridge` | `sandbox_spawn` | `_ChildHandle.tearDown()` or `onDone` | `SandboxPlugin` |
| Child `StreamSubscription` | `sandbox_spawn` | `_ChildHandle.tearDown()` or `onDone` | `SandboxPlugin` |
| `OsCallHandler` callback | `registerOsCallHandler()` | Bridge dispose (set to null) | `DefaultMontyBridge` |

### Crash Behavior

- **Bridge error during `_run`**: All error types caught, converted to
  `BridgeRunError`. `_pendingFutures` cleared in `finally`. Clean.
- **Child spawn failure**: Disposes bridge, platform, registry in catch.
  Correct cleanup-on-error.
- **`SandboxPlugin.onDispose()`**: Iterates all children, tears down alive
  ones, completes pending completers with error, clears map. Thorough.
- **OsCallHandler throws**: Exception caught in `_handleOsCall`, sent back
  to Python via `resumeWithError`. No resource leak.

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| E-1 | Low | BY DESIGN | `DefaultMontyBridge.dispose()` does not dispose the platform. Bridge doesn't own platform — caller must dispose separately. |
| E-3 | Low | BY DESIGN | Completed children persist in `SandboxPlugin._children` until `sandbox_free`. Required for output/result access. |
| E-4 | Moderate | KNOWN | No mechanism for stopping in-flight host functions. Cancel infrastructure removed; host async work runs to completion. |

---

## Summary

### Resolved (7)

| ID | Subsystem | Resolution |
|----|-----------|-----------|
| A-1 | Rust FFI | HashSet properly deletes entries |
| A-2 | Rust FFI | LIVE_HANDLES check prevents double-free |
| B-1 | Dart FFI | Zombie tracking + diagnostic logging |
| B-4 | Dart FFI | `restoreSnapshot` now frees prior handle |
| C-3 | Platform | `dispose()` force-idles active state before disposing |
| D-1 | WASM | `_invalidateSession()` on panic |
| D-2 | WASM | `wasmPanicErrorType` constant replaces raw string |

### Open (1)

| ID | Severity | Subsystem | Issue |
|----|----------|-----------|-------|
| E-4 | Moderate | Bridge | In-flight host functions not stoppable (known; cancel removed) |

### By Design (2)

| ID | Subsystem | Rationale |
|----|-----------|-----------|
| E-1 | Bridge | Bridge doesn't own platform lifecycle |
| E-3 | Bridge | Children persist for output access |

---

## Recommended Fixes

1. **E-4** (if needed in future): Accept a timeout parameter in host
   function handlers, or add a `Future.timeout()` wrapper around handler
   invocation in `_dispatchToolCall`.
