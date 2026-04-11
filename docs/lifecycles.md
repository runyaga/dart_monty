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
| ~~B-4~~ | ~~Moderate~~ | RESOLVED | `restoreSnapshot` now frees prior handle before loading new snapshot. |

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
| ~~C-3~~ | ~~Moderate~~ | RESOLVED | `dispose()` force-idles active state before disposing. |

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
| ~~D-2~~ | ~~Moderate~~ | RESOLVED | `wasmPanicErrorType` constant replaces raw string matching. |

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

## F. OsCall / VFS Handlers (`lib/src/bridge/os_call/`)

The OsCall subsystem intercepts Python standard-library operations
(`pathlib`, `os`, `datetime`) and routes them through Dart handlers.
Two filesystem strategies provide the **VFS** layer:

- **MemoryFsOsCallHandler** — pure in-memory VFS (ephemeral, platform-agnostic,
  works on WASM). Backed by `package:file`'s `MemoryFileSystem`.
- **SandboxedNativeFsHandler** — chrooted real filesystem with path-traversal
  and symlink-escape protection.

Non-filesystem handlers cover environment variables (`EnvOsCallHandler`)
and date/time (`TimeOsCallHandler`). A `RouterOsCallHandler` composes
them by operation-name prefix.

### Resources

| Resource | Allocated by | Freed by | Owner |
|----------|-------------|----------|-------|
| `OsCallHandler` (abstract) | Caller (`createDefaultOsCallHandler()` or custom) | `RouterOsCallHandler.dispose()` via bridge/session dispose | `DefaultMontyBridge` or `MontySession` |
| `RouterOsCallHandler` child map | Constructor | `dispose()` iterates + dedup-disposes children | `RouterOsCallHandler` |
| `MemoryFileSystem` (VFS backing store) | `MemoryFsOsCallHandler` constructor | GC (no explicit dispose) | `MemoryFsOsCallHandler` |
| `SandboxedNativeFsHandler._root` (resolved path) | Factory constructor (resolves symlinks) | N/A — handler does not own root directory | Caller |
| `EnvOsCallHandler.environment` map | Constructor (caller-provided) | GC | `EnvOsCallHandler` |
| `TimeOsCallHandler._clock` | Constructor | GC | `TimeOsCallHandler` |

### Ownership Chain

1. **`DefaultMontyBridge`** accepts handler via `registerOsCallHandler()`.
   Disposes it in `bridge.dispose()` with `unawaited(_osCallHandler?.dispose())`.
2. **`MontySession`** accepts optional handler in constructor.
   Disposes it in `session.dispose()` with `unawaited(_osCallHandler?.dispose())`.
3. These two owners are mutually exclusive by design: `MontySession` is for
   simple `run()` mode; `DefaultMontyBridge` is for full bridge mode. A handler
   instance should never be given to both.
4. **`RouterOsCallHandler.dispose()`** iterates child handlers using a
   `Set<OsCallHandler>` to deduplicate. A handler registered under multiple
   prefixes (e.g., `TimeOsCallHandler` for both `'date.'` and `'datetime.'`)
   is disposed exactly once. The fallback handler, if present, is also disposed.

### Crash Behavior

- **Handler throws `OsCallException`**: Caught by `_handleOsCall` (`on Object`),
  logged, sent back to Python via `resumeWithError()`. No handler leak.
  Subclasses (`OsCallPermissionError`, `OsCallFileNotFoundError`) are
  translated to the corresponding Python exception type.
- **Handler throws unexpected error**: Same `on Object catch (e, st)` path.
  Error logged with stack trace, resumed as Python error string.
- **No handler registered**: Bridge resumes with `PermissionError` message.
  No crash.
- **Handler `dispose()` throws**: Fire-and-forget via `unawaited()` in both
  `DefaultMontyBridge.dispose()` and `MontySession.dispose()`. Error does not
  propagate to caller.
- **VFS path escape (`SandboxedNativeFsHandler`)**: Throws
  `OsCallPermissionError`. Symlink escape after initial resolution also caught
  by `_safeResolved()`. All caught by `_handleOsCall`.
- **Web: `os.*` call with no handler**: Router has no `'os.'` prefix on web.
  `UnsupportedError` thrown by router, caught by bridge, sent back to Python.

### Findings

| ID | Severity | Status | Description |
|----|----------|--------|-------------|
| F-1 | Low | BY DESIGN | Dual ownership: both `DefaultMontyBridge` and `MontySession` accept and dispose an `OsCallHandler`. They are mutually exclusive entry points — never share a handler instance across both. |
| F-2 | Safe | OK | `RouterOsCallHandler.dispose()` deduplicates via `Set`. Handler registered under multiple prefixes is disposed once. Fallback handler is also disposed. |
| F-3 | Safe | OK | `SandboxedNativeFsHandler` does not own its root directory. Caller must clean up. Documented in dispose comment and constructor doc. |
| F-4 | Safe | OK | `MemoryFsOsCallHandler` (VFS) has no dispose logic. `MemoryFileSystem` is GC-collected. Files are ephemeral by design. |
| F-5 | Safe | OK | `_handleOsCall` catches `on Object` — no unhandled exception can leak from a handler call. Error is always sent back to Python. |
| F-6 | Low | OK | `unawaited()` on handler dispose in both bridge and session means dispose errors are fire-and-forget. If a handler's `dispose()` throws, it silently fails. |
| F-7 | Info | OK | Web default factory omits `os.*` prefix. Any `os.getenv` call from Python hits router's `UnsupportedError` path, which the bridge catches and sends back as a Python error. Correct. |
| F-8 | Low | OK | Path escape protection in `SandboxedNativeFsHandler` uses `startsWith` on normalized paths plus symlink re-check. Factory constructor resolves root symlinks at construction. TOCTOU: if root itself becomes a symlink after construction, the check uses the stale resolved path. Low practical risk (root is typically a temp dir). |

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

### By Design (3)

| ID | Subsystem | Rationale |
|----|-----------|-----------|
| E-1 | Bridge | Bridge doesn't own platform lifecycle |
| E-3 | Bridge | Children persist for output access |
| F-1 | OsCall/VFS | Dual ownership is by design — bridge mode and session mode are mutually exclusive |

### Reviewed — No Action (7)

| ID | Subsystem | Note |
|----|-----------|------|
| F-2 | OsCall | Router dedup dispose correct |
| F-3 | OsCall/VFS | Sandbox handler doesn't own root (documented) |
| F-4 | OsCall/VFS | MemoryFS (VFS) is GC-collected |
| F-5 | OsCall | All handler errors caught by bridge |
| F-6 | OsCall | Dispose errors are fire-and-forget (acceptable) |
| F-7 | OsCall/VFS | Web `os.*` correctly unsupported |
| F-8 | OsCall/VFS | Path escape TOCTOU — low practical risk |

---

## Recommended Fixes

1. **E-4** (if needed in future): Accept a timeout parameter in host
   function handlers, or add a `Future.timeout()` wrapper around handler
   invocation in `_dispatchToolCall`.
