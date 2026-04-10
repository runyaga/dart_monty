# Resource Lifecycle Audit

Inventories every resource allocated across dart_monty subsystems,
how each is freed, what happens on crash, and known gaps.

Last updated: 2026-04-09 (monty 0.0.10, cancel infrastructure removed)

---

## A. Rust FFI Layer (`native/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| `MontyHandle` (heap) | `monty_create` → `Box::into_raw` | `monty_free` → `Box::from_raw` | Dart FFI caller |
| `LIVE_HANDLES` entry | `MontyHandle::new` | `MontyHandle::Drop` | Static global |
| C strings (error messages) | `to_c_string` (`error.rs:8`) | `monty_string_free` (`lib.rs`) | Dart FFI caller |
| Snapshot byte buffer | `monty_snapshot` (`lib.rs`) | `monty_bytes_free` (`lib.rs`) | Dart FFI caller |

### Crash Behavior

- **Panic during execution**: Caught by `catch_ffi_panic` (`error.rs:13`).
  Handle stays valid. Returns error tag. No leak.
- **`monty_free` never called**: Handle leaks permanently.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| A-1 | Low | `LIVE_HANDLES` never compacts dead entries. Minor growth over millions of handles. |
| A-2 | Critical | No double-free protection on `monty_free`. Second call on same pointer is UB. Dart layer prevents this via null-before-free pattern. |

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
- **`terminate()` timeout**: After 5s, if isolate won't die: increments
  `_zombieCount`. Handle may leak.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| B-1 | Critical | Zombie isolate leaks Rust `MontyHandle` permanently. Tracked by `_zombieCount`. Correct safety choice but no recovery. |
| B-3 | Safe | `_freeHandle` nulls `_handle` before calling `free()`. Prevents double-free within `FfiCoreBindings`. |
| B-4 | Moderate | `restoreSnapshot` does not free prior handle. Protected by state machine `assertIdle` but no defensive code. |

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

| ID | Severity | Description |
|----|----------|-------------|
| C-3 | Moderate | No "disposed while active" recovery. Concurrent resume and dispose could race on FFI handle. |

---

## D. WASM Bindings (`packages/dart_monty_wasm/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| JS Worker session | `WasmBindingsJs.createSession()` | `disposeSession()` | `WasmCoreBindings` |
| Session ID (String) | `createSession` | Nulled on dispose | `WasmCoreBindings` |

### Crash Behavior

- **WASM panic/trap**: Throws `MontyPanicError`. Worker is likely dead
  but `_sessionId` is NOT nulled.
- **Worker termination during in-flight call**: Pending `JSPromise.toDart`
  rejects. Error is classified by string matching.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| D-1 | Critical | Session not invalidated after `MontyPanicError`. Subsequent calls use dead Worker. Must call `dispose()` after catching panic. |
| D-2 | Moderate | Error classification uses string matching (`'Panic'`, `'RuntimeError'`). Fragile if Worker error format changes. |

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

### Crash Behavior

- **Bridge error during `_run`**: All error types caught, converted to
  `BridgeRunError`. `_pendingFutures` cleared in `finally`. Clean.
- **Child spawn failure**: Disposes bridge, platform, registry in catch.
  Correct cleanup-on-error.
- **`SandboxPlugin.onDispose()`**: Iterates all children, tears down alive
  ones, completes pending completers with error, clears map. Thorough.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| E-1 | Low | `DefaultMontyBridge.dispose()` does not dispose the platform. By design (bridge doesn't own platform), but caller must dispose separately. |
| E-3 | Low | Completed children persist in `SandboxPlugin._children` until `sandbox_free`. Bridge/platform already disposed, minor memory overhead only. |
| E-4 | Moderate | No mechanism for stopping in-flight host functions. Host async work continues even after bridge dispose. |

---

## Summary by Severity

### Critical (resource leak or corruption risk)

| ID | Subsystem | Issue |
|----|-----------|-------|
| A-2 | Rust FFI | No double-free protection on `monty_free` at Rust level |
| B-1 | Dart FFI | Zombie isolate leaks Rust handle permanently |
| D-1 | WASM | Session not invalidated after panic — dead Worker reuse |

### Moderate (functional correctness under failure)

| ID | Subsystem | Issue |
|----|-----------|-------|
| B-4 | Dart FFI | `restoreSnapshot` doesn't free prior handle (state machine guards) |
| C-3 | Platform | No dispose-while-active race protection |
| D-2 | WASM | String-based error classification is fragile |
| E-4 | Bridge | In-flight host functions not stoppable |

### Low (minor or theoretical)

| ID | Subsystem | Issue |
|----|-----------|-------|
| A-1 | Rust FFI | Set never compacts dead entries |
| E-1 | Bridge | Bridge doesn't own platform lifecycle |
| E-3 | Bridge | Completed children persist in sandbox map |

---

## Recommended Fixes (Priority Order)

1. **D-1**: Null `_sessionId` when `MontyPanicError` is thrown. Add
   `_invalidateSession()` called from all dead-Worker error paths.

2. **A-2**: Add `LIVE_HANDLES` lookup in `monty_free` before
   `Box::from_raw`. Remove entry atomically to prevent double-free.

3. **B-1**: Add diagnostic logging when `_zombieCount` exceeds a threshold
   (e.g., 3). Helps detect patterns that cause zombie accumulation.
