# FFI Handle Lifecycle — Debug Notes

## The Bug (#271)

Creating and disposing 2+ `AgentSession` instances in the same process,
then creating a 3rd and calling an HTTP host function, causes a SEGFAULT.

## Root Cause: NativeFinalizer Race

### Subsystems involved

1. **Rust `MontyHandle`** (`native/src/handle.rs`) — opaque handle holding
   interpreter state. Created by `monty_create`, freed by `monty_free`.

2. **Rust `LIVE_HANDLES`** (`native/src/lib.rs:124`) — global `HashSet<usize>`
   tracking live handle pointers. Prevents double-free.

3. **Dart `FfiCoreBindings`** (`dart_monty_core/lib/src/ffi/ffi_core_bindings.dart`) —
   adapts FFI bindings to the core interface. Owns `_handle` (int) and
   `_guard` (`_HandleGuard`).

4. **Dart `_HandleGuard`** (line 18) — `Finalizable` token attached to
   a `NativeFinalizer`. When GC'd without explicit detach, the finalizer
   calls `monty_free` on the handle address.

5. **Dart `_handleFinalizer`** (line 28) — `NativeFinalizer` backed by
   `monty_free`. Attached per handle, detached on explicit free.

6. **Dart `BaseMontyPlatform`** (`lib/src/platform/base_monty_platform.dart`) —
   calls `_bindings.dispose()` on platform disposal.

7. **Dart `AgentSession`** (`lib/src/bridge/agent_session.dart`) —
   creates `Monty` → `MontyFfi` → `FfiCoreBindings`. Dispose chain:
   `session.dispose()` → `bridge.dispose()` → `monty.dispose()` →
   `platform.dispose()` → `bindings.dispose()` → `_freeHandle()`.

### The race condition

```text
Session 1:
  monty_create() → handle_A at address 0x1000
  _storeHandle(0x1000) → guard_1 attached to finalizer
  _freeHandle(0x1000):
    detach(guard_1) → OK
    monty_free(0x1000) → freed, removed from LIVE_HANDLES
  dispose() complete

Session 2:
  monty_create() → handle_B at address 0x2000
  [same lifecycle as Session 1]
  monty_free(0x2000) → freed

** GC runs: guard_1 and guard_2 collected. Finalizer may fire. **
** LIVE_HANDLES check prevents double-free — but what about: **

Session 3:
  monty_create() → handle_C at address 0x1000 (REUSED!)
  _storeHandle(0x1000) → guard_3 attached

** GC finalizer for guard_1 fires (delayed): **
**   monty_free(0x1000) → LIVE_HANDLES says it's live! **
**   Frees handle_C (Session 3's active handle!) **
**   → Session 3's next monty_resume hits freed memory → SEGFAULT **
```

### Why address reuse matters

Rust's allocator (`jemalloc` or system) reuses freed memory addresses.
After `monty_free(0x1000)` deallocates handle_A, a subsequent
`monty_create()` may allocate handle_C at the same address 0x1000.

The `LIVE_HANDLES` set sees 0x1000 as a valid live handle (it was
re-inserted by Session 3's `monty_create`). The stale finalizer's
`monty_free(0x1000)` passes the LIVE_HANDLES check and frees Session 3's
handle while it's still in use.

### Fix options

**Option A: Detach finalizer using a unique token (not the guard itself)**

```dart
// Instead of:
_handleFinalizer.attach(guard, pointer);  // token is guard
_handleFinalizer.detach(guard);            // might not work if GC'd

// Use:
final token = Object();
_handleFinalizer.attach(guard, pointer, detach: token);
_handleFinalizer.detach(token);  // works even if guard is GC'd
```

**Option B: Use a generation counter in LIVE_HANDLES**

Instead of `HashSet<usize>`, use `HashMap<usize, u64>` with a monotonic
generation. Each `monty_create` increments the generation. The finalizer
must match both address AND generation.

**Option C: Never rely on NativeFinalizer for handle cleanup**

Remove the `_HandleGuard` / `NativeFinalizer` entirely. Rely solely on
explicit `dispose()` calls. Leaked handles are a memory issue, not a
crash issue.

### Recommended: Option A

Minimal change, keeps the GC safety net, prevents the race.
