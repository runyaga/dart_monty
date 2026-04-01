# Resource Lifecycle Audit

Inventories every resource allocated across dart_monty subsystems,
how each is freed, what happens on cancel/crash, and known gaps.

Last updated: 2026-04-01 (monty 0.0.9)

---

## A. Rust FFI Layer (`native/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| `MontyHandle` (heap) | `monty_create` → `Box::into_raw` | `monty_free` → `Box::from_raw` | Dart FFI caller |
| Cancel flag (`Arc<AtomicBool>`) | `MontyHandle::new` | Dropped with `MontyHandle` | Handle |
| `CANCEL_REGISTRY` entry | `MontyHandle::new` (`handle.rs:154`) | `MontyHandle::Drop` (`handle.rs:766`) | Static global |
| `HANDLE_REGISTRY` entry | `MontyHandle::new` (`handle.rs:160`) | `MontyHandle::Drop` (`handle.rs:773`) | Static global |
| C strings (error messages) | `to_c_string` (`error.rs:8`) | `monty_string_free` (`lib.rs:562`) | Dart FFI caller |
| Snapshot byte buffer | `monty_snapshot` (`lib.rs:476`) | `monty_bytes_free` (`lib.rs:570`) | Dart FFI caller |

### Cancel/Crash Behavior

- **Panic during execution**: Caught by `catch_ffi_panic` (`error.rs:13`).
  Handle stays valid. Returns error tag. No leak.
- **`monty_free` never called**: Handle leaks permanently. Both registry
  entries persist. `CANCEL_REGISTRY` `Weak` remains upgradeable because
  the `Arc` inside the leaked handle is never dropped.
- **`monty_free_by_id`** (`handle.rs:749`): Crash-only disposal path.
  Removes from `HANDLE_REGISTRY`, calls `Box::from_raw` which triggers
  `Drop` (cleans up `CANCEL_REGISTRY`).

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| A-1 | Low | `CANCEL_REGISTRY` never compacts dead `Weak` entries. Minor growth over millions of handles. |
| A-2 | Critical | No double-free protection on `monty_free`. Second call on same pointer is UB. Dart layer prevents this via null-before-free pattern. |

---

## B. Dart FFI Bindings (`packages/dart_monty_ffi/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| FFI handle (int address) | `FfiCoreBindings.run/start` | `_freeHandle` → `_bindings.free()` | `FfiCoreBindings` |
| Handle ID (int) | Received from Rust | Nulled on free | `FfiCoreBindings` |
| Background isolate | `NativeIsolateBindingsImpl.init` | `dispose()`/`terminate()` → `Isolate.kill` | `NativeIsolateBindingsImpl` |
| `ReceivePort` | `init()` | `dispose()` → `.close()` | `NativeIsolateBindingsImpl` |
| Pending completers map | Per request | `_failAllPending` on dispose/crash | `NativeIsolateBindingsImpl` |

### Cancel/Crash Behavior

- **`FfiCoreBindings.run()`** (`ffi_core_bindings.dart:56`): `try/finally`
  always frees handle. Correct.
- **`FfiCoreBindings.start()` error** (`ffi_core_bindings.dart:74`): `catch`
  frees handle, nulls ID. Correct.
- **Isolate dies unexpectedly**: `addOnExitListener` fires null message.
  `_failAllPending` completes all futures with errors.
- **`terminate()` timeout** (`native_isolate_bindings_impl.dart:489`):
  After 5s, if isolate won't die: increments `_zombieCount`, deliberately
  skips `freeById` (handle may still be in use by zombie isolate).

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| B-1 | Critical | Zombie isolate leaks Rust `MontyHandle` permanently. Tracked by `_zombieCount`. Correct safety choice but no recovery. |
| B-2 | Low | `cancel()` is no-op before `_handleId` notification arrives. Very narrow race window. |
| B-3 | Safe | `_freeHandle` nulls `_handle` before calling `free()`. Prevents double-free within `FfiCoreBindings`. |
| B-4 | Moderate | `restoreSnapshot` does not free prior handle. Protected by state machine `assertIdle` but no defensive code. |

---

## C. Platform Interface (`packages/dart_monty_platform_interface/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| State machine (`_MontyState`) | Construction | N/A (enum, not heap) | `MontyStateMixin` |
| `MontySession._state` map | Construction | `clearState()`/`dispose()` | `MontySession` |
| `MontyCancelRegistry` entries | `registerNativeCancel`/`webRegister` | `unregisterWeb` on dispose | Static global |

### Cancel/Crash Behavior

- **`BaseMontyPlatform.run()`** (`base_monty_platform.dart:94`):
  `markActive()` in try, `markIdle()` in finally. Correct.
- **`BaseMontyPlatform.resume()` error** (`base_monty_platform.dart:141`):
  Catches, calls `markIdle()`, rethrows. State machine unblocked.
- **`dispose()` while active**: Calls `_bindings.dispose()` which frees
  handle. But a concurrent in-flight resume could race with the free.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| C-1 | Moderate | `MontySession._safeStart` catches `MontyException` but not `MontyCancelledError`. Session state may be inconsistent after cancel (persist function never called). |
| C-2 | Low | `MontyCancelRegistry._webRegistry` never compacted on missed dispose. Low risk with few web sessions. |
| C-3 | Moderate | No "disposed while active" recovery. Concurrent resume and dispose could race on FFI handle. |

---

## D. WASM Bindings (`packages/dart_monty_wasm/lib/src/`)

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| JS Worker session | `WasmBindingsJs.createSession()` | `disposeSession()` / `cancel()` (terminates Worker) | `WasmCoreBindings` |
| Session ID (String) | `createSession` | Nulled on dispose/cancel | `WasmCoreBindings` |
| Web cancel registry entry | `init()` | `dispose()` / `cancel()` | `WasmCoreBindings` |

### Cancel/Crash Behavior

- **`cancel()`** (`wasm_core_bindings.dart:163`): Terminates Worker,
  unregisters from cancel registry, nulls `_sessionId`. Clean.
- **WASM panic/trap** (`wasm_core_bindings.dart:207`): Throws
  `MontyPanicError`. Worker is likely dead but `_sessionId` is NOT nulled.
- **Worker termination during in-flight call**: Pending `JSPromise.toDart`
  rejects. `_throwIfWebCancelError` classifies the error.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| D-1 | Critical | Session not invalidated after `MontyPanicError`. Subsequent calls use dead Worker. Must call `dispose()` after catching panic. |
| D-2 | Moderate | Error classification uses string matching (`'MontyCancelled:'`, `'Panic'`, `'RuntimeError'`). Fragile if Worker error format changes. |
| D-3 | Low | No `cancelById` feedback for WASM. Fire-and-forget `unawaited(bindings.cancel())`. |

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
| Child `MontyPlatform` | `sandbox_spawn` | `_ChildHandle.cancel()` or `onDone` | `SandboxPlugin` |
| Child `DefaultMontyBridge` | `sandbox_spawn` | `_ChildHandle.cancel()` or `onDone` | `SandboxPlugin` |
| Child `StreamSubscription` | `sandbox_spawn` | `_ChildHandle.cancel()` or `onDone` | `SandboxPlugin` |

### Cancel/Crash Behavior

- **Bridge error during `_run`** (`default_monty_bridge.dart:241`):
  All error types caught, converted to `BridgeRunError`. `_pendingFutures`
  cleared in `finally`. Clean.
- **Child spawn failure** (`sandbox_plugin.dart:462`): Disposes bridge,
  platform, registry in catch. Correct cleanup-on-error.
- **`SandboxPlugin.onDispose()`** (`sandbox_plugin.dart:725`): Iterates
  all children, cancels alive ones, completes pending completers with
  error, clears map. Thorough.

### Findings

| ID | Severity | Description |
|----|----------|-------------|
| E-1 | Low | `DefaultMontyBridge.dispose()` does not dispose the platform. By design (bridge doesn't own platform), but caller must dispose separately. |
| E-2 | Moderate | `dispose()` does not cancel in-flight execution. `_run` continues on a disposed bridge. StreamController may receive events after dispose. |
| E-3 | Low | Completed children persist in `SandboxPlugin._children` until `sandbox_free`. Bridge/platform already disposed, minor memory overhead only. |
| E-4 | Moderate | No cancellation mechanism for in-flight host functions. Host async work continues even after bridge cancel/dispose. |

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
| C-1 | Platform | `MontySession` doesn't catch `MontyCancelledError` |
| C-3 | Platform | No dispose-while-active race protection |
| D-2 | WASM | String-based error classification is fragile |
| E-2 | Bridge | `dispose()` doesn't cancel in-flight execution |
| E-4 | Bridge | In-flight host functions not cancellable |

### Low (minor or theoretical)

| ID | Subsystem | Issue |
|----|-----------|-------|
| A-1 | Rust FFI | Registry never compacts dead entries |
| B-2 | Dart FFI | Cancel no-op before handle ID notification |
| C-2 | Platform | Web cancel registry not compacted |
| E-1 | Bridge | Bridge doesn't own platform lifecycle |
| E-3 | Bridge | Completed children persist in sandbox map |

---

## Recommended Fixes (Priority Order)

1. **D-1**: Null `_sessionId` when `MontyPanicError` is thrown. Add
   `_invalidateSession()` called from all dead-Worker error paths.

2. **A-2**: Add `HANDLE_REGISTRY` lookup in `monty_free` before
   `Box::from_raw`. Remove entry atomically to prevent double-free.

3. **C-1**: Catch `MontyError` (sealed parent) in `MontySession._safeStart`
   instead of just `MontyException`. Ensures session state consistency
   after cancel.

4. **E-2**: Cancel the platform in `DefaultMontyBridge.dispose()` before
   setting `_isDisposed`, or document that callers must cancel first.

5. **B-1**: Add diagnostic logging when `_zombieCount` exceeds a threshold
   (e.g., 3). Helps detect patterns that cause zombie accumulation.
