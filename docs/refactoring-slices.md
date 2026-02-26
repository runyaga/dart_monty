# Refactoring Slices

Fine-grained implementation plan for the 4-commit architecture refactoring
described in `docs/architecture-analysis.md` (Section 7.7).

**Total slices:** 11
**Estimated deletions (net):** ~400 lines of duplicated logic

---

## Slice 1: Define Capability Interfaces

**Commit:** 1
**Depends on:** none

### Goal

Create `MontySnapshotCapable` and `MontyFutureCapable` abstract interfaces
in `platform_interface`, separate from `MontyPlatform`.

### Files Changed

- `packages/dart_monty_platform_interface/lib/src/monty_snapshot_capable.dart` — **created**. Abstract class with `snapshot()` and `restore()` signatures.
- `packages/dart_monty_platform_interface/lib/src/monty_future_capable.dart` — **created**. Abstract class with `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` signatures.
- `packages/dart_monty_platform_interface/lib/dart_monty_platform_interface.dart` — add exports for both new files.

### Acceptance Criteria

- [ ] `MontySnapshotCapable` declares `Future<Uint8List> snapshot()` and `Future<MontyPlatform> restore(Uint8List data)`
- [ ] `MontyFutureCapable` declares `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()`
- [ ] Both are abstract classes (not mixins), importable from the barrel export
- [ ] `dart analyze --fatal-infos` passes for `platform_interface`
- [ ] No existing code is changed; interfaces are additive only

### Gate

```bash
cd packages/dart_monty_platform_interface && dart analyze --fatal-infos
```

---

## Slice 2: Slim MontyPlatform + Implement Capabilities Across All Packages

**Commit:** 1
**Depends on:** Slice 1

### Goal

Atomic slice that removes 5 methods from `MontyPlatform` and adds
capability interface implementations on all 4 downstream classes
(`MontyFfi`, `MontyWasm`, `MontyNative`, `DartMontyWeb`). Also deletes
the `UnsupportedError`-throwing stubs from web/wasm packages. This must
be a single atomic slice because removing methods from `MontyPlatform`
breaks all downstream packages until they add `implements` for the
capability interfaces.

### Files Changed

- `packages/dart_monty_platform_interface/lib/src/monty_platform.dart` — remove 5 method declarations (`snapshot`, `restore`, `resumeAsFuture`, `resolveFutures`, `resolveFuturesWithErrors`). Keep `run`, `start`, `resume`, `resumeWithError`, `dispose`.
- `packages/dart_monty_platform_interface/test/monty_platform_test.dart` — remove 5 "throws UnimplementedError" tests for the removed methods.
- `packages/dart_monty_ffi/lib/src/monty_ffi.dart` — add `implements MontySnapshotCapable, MontyFutureCapable` to class declaration. No method body changes; all 5 methods already exist.
- `packages/dart_monty_wasm/lib/src/monty_wasm.dart` — add `implements MontySnapshotCapable` to class declaration. Delete `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` override methods (the 3 that threw `UnsupportedError`). `MontyWasm` does NOT implement `MontyFutureCapable`.
- `packages/dart_monty_wasm/test/monty_wasm_test.dart` — replace 3 `throws UnsupportedError` tests with a single `MontyWasm() is! MontyFutureCapable` type-check test. Add `MontyWasm() is MontySnapshotCapable` assertion.
- `packages/dart_monty_native/lib/src/monty_native.dart` — add `implements MontySnapshotCapable, MontyFutureCapable` to class declaration. No method body changes.
- `packages/dart_monty_web/lib/dart_monty_web.dart` — add `implements MontySnapshotCapable` to class declaration. Delete `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` override methods. `DartMontyWeb` does NOT implement `MontyFutureCapable`.
- `packages/dart_monty_web/test/dart_monty_web_test.dart` — replace `UnsupportedError` tests with capability type-check tests.

### Acceptance Criteria

- [ ] `MontyPlatform` has exactly 5 methods: `run`, `start`, `resume`, `resumeWithError`, `dispose`
- [ ] `MontyFfi` implements `MontySnapshotCapable` and `MontyFutureCapable`
- [ ] `MontyWasm` implements `MontySnapshotCapable` only (not `MontyFutureCapable`)
- [ ] `MontyNative` implements both `MontySnapshotCapable` and `MontyFutureCapable`
- [ ] `DartMontyWeb` implements `MontySnapshotCapable` only
- [ ] 3 `UnsupportedError`-throwing method overrides deleted from `MontyWasm`
- [ ] 3 `UnsupportedError`-throwing method overrides deleted from `DartMontyWeb`
- [ ] Tests verify type-check assertions for all impl classes
- [ ] `dart analyze --fatal-infos` passes for all 5 packages
- [ ] `dart test` passes for all 5 packages

### Gate

```bash
bash tool/gate.sh --dart-only
```

---

## Slice 3: Update MockMontyPlatform and LadderRunner for Capabilities

**Commit:** 1
**Depends on:** Slice 2

### Goal

Update `MockMontyPlatform` to implement capability interfaces. Update
`LadderRunner` to check for capabilities before running futures-related
fixtures.

### Files Changed

- `packages/dart_monty_platform_interface/lib/src/mock_monty_platform.dart` — add `implements MontySnapshotCapable, MontyFutureCapable` to class declaration. Method implementations already exist; no body changes needed.
- `packages/dart_monty_platform_interface/lib/src/testing/ladder_runner.dart` — in `runIterativeFixture`, wrap `resumeAsFuture()` / `resolveFutures()` / `resolveFuturesWithErrors()` calls with `platform is MontyFutureCapable` checks. If the platform does not support futures, skip the fixture (via `markTestSkipped` or equivalent skip pattern) instead of throwing.
- `packages/dart_monty_platform_interface/test/monty_platform_test.dart` — if any tests reference the removed `MontyPlatform` methods through `_TestMontyPlatform`, update them.

### Acceptance Criteria

- [ ] `MockMontyPlatform` implements `MontySnapshotCapable` and `MontyFutureCapable`
- [ ] `LadderRunner` gracefully skips futures fixtures when platform is not `MontyFutureCapable`
- [ ] `LadderRunner` gracefully skips snapshot fixtures when platform is not `MontySnapshotCapable`
- [ ] All platform_interface tests pass
- [ ] `dart analyze --fatal-infos` passes

### Gate

```bash
cd packages/dart_monty_platform_interface && dart analyze --fatal-infos && dart test
```

---

## Slice 4: Define CoreRunResult, CoreProgressResult, and MontyCoreBindings

**Commit:** 2
**Depends on:** Slice 3

### Goal

Create the unified `MontyCoreBindings` abstract class and its associated
result types (`CoreRunResult`, `CoreProgressResult`) in `platform_interface`.
These are the intermediate result types returned by bindings adapters,
before `BaseMontyPlatform` translates them into domain types.

### Files Changed

- `packages/dart_monty_platform_interface/lib/src/core_bindings.dart` — **created**. Contains:
  - `CoreRunResult` — `{bool ok, Object? value, MontyResourceUsage? usage, String? error, String? excType, List<dynamic>? traceback}`
  - `CoreProgressResult` — `{String state, Object? value, String? functionName, List<Object?>? arguments, Map<String,Object?>? kwargs, int? callId, bool? methodCall, List<int>? pendingCallIds, String? error, String? excType, List<dynamic>? traceback}`
  - `MontyCoreBindings` — abstract class with `Future<bool> init()`, `Future<CoreRunResult> run(...)`, `Future<CoreProgressResult> start(...)`, `Future<CoreProgressResult> resume(String valueJson)`, `Future<CoreProgressResult> resumeWithError(String errorMessage)`, `Future<CoreProgressResult> resumeAsFuture()`, `Future<CoreProgressResult> resolveFutures(String resultsJson, String errorsJson)`, `Future<Uint8List> snapshot()`, `Future<void> restoreSnapshot(Uint8List data)`, `Future<void> dispose()`
- `packages/dart_monty_platform_interface/lib/dart_monty_platform_interface.dart` — add export for `core_bindings.dart`

### Acceptance Criteria

- [ ] `CoreRunResult` is a final class with named constructor fields
- [ ] `CoreProgressResult` is a final class with named constructor fields
- [ ] `MontyCoreBindings` is an abstract class with all method signatures
- [ ] `MontyCoreBindings` methods for futures (`resumeAsFuture`, `resolveFutures`) are included since adapters may or may not implement them
- [ ] `dart analyze --fatal-infos` passes for `platform_interface`
- [ ] No existing code is modified; this is additive

### Gate

```bash
cd packages/dart_monty_platform_interface && dart analyze --fatal-infos
```

---

## Slice 5: Create BaseMontyPlatform with Shared Translation Logic

**Commit:** 2
**Depends on:** Slice 4

### Goal

Create `BaseMontyPlatform` — an abstract class extending `MontyPlatform`
with `MontyStateMixin` that delegates to a `MontyCoreBindings` instance.
Implements all 5 core methods (`run`, `start`, `resume`, `resumeWithError`,
`dispose`) plus shared translation logic (`translateRunResult`,
`translateProgress`, `encodeLimits`, `encodeExternalFunctions`). Also
includes `_ensureInitialized()` for lazy-init pattern used by WASM/Desktop.

### Files Changed

- `packages/dart_monty_platform_interface/lib/src/base_monty_platform.dart` — **created**. Contains:
  - `BaseMontyPlatform` abstract class, `extends MontyPlatform with MontyStateMixin`
  - Constructor takes `MontyCoreBindings bindings`
  - Implements `run()`, `start()`, `resume()`, `resumeWithError()`, `dispose()`
  - Shared private methods: `_translateRunResult(CoreRunResult)`, `_translateProgress(CoreProgressResult)`, `_encodeLimits(MontyLimits?)`, `_encodeExternalFunctions(List<String>?)`
  - Calls `bindings.init()` lazily on first execution method call
  - State transitions: complete -> markIdle, pending/resolve_futures -> markActive, error -> markIdle + throw MontyException
- `packages/dart_monty_platform_interface/lib/dart_monty_platform_interface.dart` — add export for `base_monty_platform.dart`
- `packages/dart_monty_platform_interface/test/base_monty_platform_test.dart` — **created**. Unit tests using a `FakeCoreBindings` that returns canned `CoreRunResult`/`CoreProgressResult`. Tests cover: run success, run error, start complete, start pending, start error, resume, resumeWithError, dispose, state guards, limits encoding, externalFunctions encoding, lazy init, double dispose safety.

### Acceptance Criteria

- [ ] `BaseMontyPlatform` compiles and is exported
- [ ] `run()` delegates to `bindings.run()` then `_translateRunResult()`
- [ ] `start()` delegates to `bindings.start()` then `_translateProgress()`
- [ ] `resume()` / `resumeWithError()` delegate similarly with active-state guards
- [ ] `dispose()` calls `bindings.dispose()` and `markDisposed()`
- [ ] `_translateRunResult` maps `CoreRunResult.ok` to `MontyResult` and `!ok` to `MontyException`
- [ ] `_translateProgress` maps state strings to `MontyComplete`, `MontyPending`, `MontyResolveFutures`, or throws `MontyException`
- [ ] `_encodeLimits` produces JSON string or null
- [ ] `_encodeExternalFunctions` produces JSON array string or null
- [ ] All new tests pass via `FakeCoreBindings`
- [ ] `dart analyze --fatal-infos` and `dart test` pass for `platform_interface`

### Gate

```bash
cd packages/dart_monty_platform_interface && dart analyze --fatal-infos && dart test
```

---

## Slice 6: Create FfiCoreBindings Adapter

**Commit:** 2
**Depends on:** Slice 4

### Goal

Create `FfiCoreBindings` that adapts `NativeBindings` (sync, int handles,
`RunResult`/`ProgressResult`) to the `MontyCoreBindings` interface (async,
`CoreRunResult`/`CoreProgressResult`). This adapter owns handle lifecycle
and translates between the FFI-specific result types and the core types.

### Files Changed

- `packages/dart_monty_ffi/lib/src/ffi_core_bindings.dart` — **created**. Contains:
  - `FfiCoreBindings implements MontyCoreBindings`
  - Constructor takes `NativeBindings` instance
  - Manages handle lifecycle internally (`int? _handle`)
  - `init()` returns `Future.value(true)` (FFI needs no async init)
  - `run()` — calls `_bindings.create()`, `_applyLimits()`, `_bindings.run()`, `_bindings.free()`, translates `RunResult` to `CoreRunResult`
  - `start()` — calls `_bindings.create()`, `_applyLimits()`, `_bindings.start()`, translates `ProgressResult` to `CoreProgressResult`, stores handle if pending
  - `resume()` / `resumeWithError()` / `resumeAsFuture()` / `resolveFutures()` — delegate to `_bindings` methods with handle, translate result
  - `snapshot()` — delegates to `_bindings.snapshot(_handle)`
  - `restoreSnapshot()` — calls `_bindings.restore()`, stores new handle
  - `dispose()` — frees handle if active, no-op otherwise
  - Private `_applyLimits()`, `_translateRunResult()`, `_translateProgressResult()` extracted from current `MontyFfi`
- `packages/dart_monty_ffi/lib/dart_monty_ffi.dart` — add export for `ffi_core_bindings.dart`
- `packages/dart_monty_ffi/test/ffi_core_bindings_test.dart` — **created**. Uses existing `MockNativeBindings` to test the adapter in isolation. Verifies correct translation of `RunResult` -> `CoreRunResult`, `ProgressResult` -> `CoreProgressResult`, handle lifecycle, limits application.

### Acceptance Criteria

- [ ] `FfiCoreBindings` implements all `MontyCoreBindings` methods
- [ ] Handle creation, limits application, and freeing are encapsulated
- [ ] `RunResult(tag: 0, resultJson: ...)` maps to `CoreRunResult(ok: true, ...)`
- [ ] `RunResult(tag: 1, ...)` maps to `CoreRunResult(ok: false, ...)`
- [ ] `ProgressResult(tag: 0)` maps to `CoreProgressResult(state: 'complete', ...)`
- [ ] `ProgressResult(tag: 1)` maps to `CoreProgressResult(state: 'pending', ...)`
- [ ] `ProgressResult(tag: 2)` maps to `CoreProgressResult(state: 'error', ...)`
- [ ] `ProgressResult(tag: 3)` maps to `CoreProgressResult(state: 'resolve_futures', ...)`
- [ ] All adapter tests pass
- [ ] `dart analyze --fatal-infos` passes for `dart_monty_ffi`

### Gate

```bash
cd packages/dart_monty_ffi && dart analyze --fatal-infos && dart test
```

---

## Slice 7: Create WasmCoreBindings Adapter

**Commit:** 2
**Depends on:** Slice 4

### Goal

Create `WasmCoreBindings` that adapts `WasmBindings` (async,
`WasmRunResult`/`WasmProgressResult`) to the `MontyCoreBindings` interface.
This adapter translates between the WASM-specific result types and the core
types. It also provides synthetic resource usage where WASM doesn't expose
real values.

### Files Changed

- `packages/dart_monty_wasm/lib/src/wasm_core_bindings.dart` — **created**. Contains:
  - `WasmCoreBindings implements MontyCoreBindings`
  - Constructor takes `WasmBindings` instance
  - `init()` delegates to `_bindings.init()`
  - `run()` — delegates to `_bindings.run(code, limitsJson, scriptName)`, translates `WasmRunResult` to `CoreRunResult` (usage is null since WASM doesn't expose it)
  - `start()` — delegates to `_bindings.start(...)`, translates `WasmProgressResult` to `CoreProgressResult`
  - `resume()` / `resumeWithError()` — delegate to `_bindings`, translate result
  - `resumeAsFuture()` / `resolveFutures()` — throw `UnsupportedError` (WASM doesn't support these)
  - `snapshot()` — delegates to `_bindings.snapshot()`
  - `restoreSnapshot()` — delegates to `_bindings.restore(data)`
  - `dispose()` — delegates to `_bindings.dispose()`
  - Private `_translateRunResult()`, `_translateProgressResult()` extracted from current `MontyWasm`
- `packages/dart_monty_wasm/lib/dart_monty_wasm.dart` — add export for `wasm_core_bindings.dart`
- `packages/dart_monty_wasm/test/wasm_core_bindings_test.dart` — **created**. Uses existing `MockWasmBindings` to test the adapter in isolation. Verifies correct translation of `WasmRunResult` -> `CoreRunResult`, `WasmProgressResult` -> `CoreProgressResult`.

### Acceptance Criteria

- [ ] `WasmCoreBindings` implements all `MontyCoreBindings` methods
- [ ] `WasmRunResult(ok: true, value: 4)` maps to `CoreRunResult(ok: true, value: 4, usage: null)`
- [ ] `WasmRunResult(ok: false, error: ...)` maps to `CoreRunResult(ok: false, error: ...)`
- [ ] `WasmProgressResult(ok: true, state: 'complete', ...)` maps correctly
- [ ] `WasmProgressResult(ok: true, state: 'pending', ...)` maps correctly
- [ ] `WasmProgressResult(ok: false, ...)` maps to error state
- [ ] `resumeAsFuture()` and `resolveFutures()` throw `UnsupportedError`
- [ ] All adapter tests pass
- [ ] `dart analyze --fatal-infos` passes for `dart_monty_wasm`

### Gate

```bash
cd packages/dart_monty_wasm && dart analyze --fatal-infos && dart test
```

---

## Slice 8: Migrate MontyFfi to BaseMontyPlatform

**Commit:** 3
**Depends on:** Slice 5, Slice 6

### Goal

Rewrite `MontyFfi` to extend `BaseMontyPlatform` instead of
`MontyPlatform with MontyStateMixin`. Delete all duplicated logic (state
guards, run result decoding, progress handling, limits encoding) that is now
in `BaseMontyPlatform`. The only methods remaining in `MontyFfi` are the
capability-interface methods (`snapshot`, `restore`, `resumeAsFuture`,
`resolveFutures`, `resolveFuturesWithErrors`) and the constructor.

### Files Changed

- `packages/dart_monty_ffi/lib/src/monty_ffi.dart` — rewrite:
  - Change `extends MontyPlatform with MontyStateMixin` to `extends BaseMontyPlatform implements MontySnapshotCapable, MontyFutureCapable`
  - Constructor passes `FfiCoreBindings(bindings)` to `super`
  - Delete: `run()`, `start()`, `resume()`, `resumeWithError()`, `dispose()`, `_handleProgress()`, `_decodeRunResult()`, `_applyLimits()`, `_freeHandle()`, `_handle` field
  - Keep: `snapshot()`, `restore()`, `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` (these delegate to the bindings but need handle/state management specific to capabilities)
  - Keep: `backendName` getter, `_withHandle` named constructor for `restore()`
- `packages/dart_monty_ffi/test/monty_ffi_test.dart` — tests should pass with no changes (behavioral parity). Minor adjustments may be needed if `MontyFfi` constructor signature changes.

### Acceptance Criteria

- [ ] `MontyFfi` extends `BaseMontyPlatform`
- [ ] `MontyFfi` no longer has `run()`, `start()`, `resume()`, `resumeWithError()`, `dispose()` overrides
- [ ] All existing `monty_ffi_test.dart` tests pass without modification (behavioral parity)
- [ ] `MontyFfi` is ~60-80 lines instead of ~340 lines
- [ ] `dart analyze --fatal-infos` and `dart test` pass for `dart_monty_ffi`

### Gate

```bash
cd packages/dart_monty_ffi && dart analyze --fatal-infos && dart test
```

---

## Slice 9: Migrate MontyWasm to BaseMontyPlatform

**Commit:** 3
**Depends on:** Slice 5, Slice 7

### Goal

Rewrite `MontyWasm` to extend `BaseMontyPlatform` instead of
`MontyPlatform with MontyStateMixin`. Delete all duplicated logic. The only
methods remaining in `MontyWasm` are `snapshot()`, `restore()`, and the
constructor.

### Files Changed

- `packages/dart_monty_wasm/lib/src/monty_wasm.dart` — rewrite:
  - Change `extends MontyPlatform with MontyStateMixin` to `extends BaseMontyPlatform implements MontySnapshotCapable`
  - Constructor passes `WasmCoreBindings(bindings)` to `super`
  - Delete: `run()`, `start()`, `resume()`, `resumeWithError()`, `dispose()`, `_translateRunResult()`, `_translateProgress()`, `_encodeLimits()`, `_parseTraceback()`, `_ensureInitialized()`, `_initialized`, `_syntheticUsage`, `initialize()`
  - Keep: `snapshot()`, `restore()`, `backendName`
- `packages/dart_monty_wasm/test/monty_wasm_test.dart` — tests should pass with no changes (behavioral parity). Remove the `initialize()` tests if `initialize()` is now handled by `BaseMontyPlatform._ensureInitialized()`. Adjust if constructor signature changes.

### Acceptance Criteria

- [ ] `MontyWasm` extends `BaseMontyPlatform`
- [ ] `MontyWasm` no longer has `run()`, `start()`, `resume()`, `resumeWithError()`, `dispose()` overrides
- [ ] All existing `monty_wasm_test.dart` tests pass (behavioral parity)
- [ ] `MontyWasm` is ~40-60 lines instead of ~274 lines
- [ ] `dart analyze --fatal-infos` and `dart test` pass for `dart_monty_wasm`

### Gate

```bash
cd packages/dart_monty_wasm && dart analyze --fatal-infos && dart test
```

---

## Slice 10: Delete NativeRunResult and NativeProgressResult Wrapper Types

**Commit:** 4
**Depends on:** Slice 8, Slice 9

### Goal

Remove the unnecessary `NativeRunResult` and `NativeProgressResult`
wrapper types. `NativeIsolateBindings` returns `MontyResult` and `MontyProgress`
directly.

### Files Changed

- `packages/dart_monty_native/lib/src/native_isolate_bindings.dart` — delete `NativeRunResult` and `NativeProgressResult` classes. Change method return types:
  - `run()` returns `Future<MontyResult>` (was `Future<NativeRunResult>`)
  - `start()`, `resume()`, `resumeWithError()`, `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` return `Future<MontyProgress>` (was `Future<NativeProgressResult>`)
- `packages/dart_monty_native/lib/src/native_isolate_bindings_impl.dart` — update `NativeIsolateBindingsImpl` to match new return types. Remove `.result` / `.progress` wrapping:
  - `run()` returns `MontyResult` directly from `_RunResponse.result`
  - `start()` etc. return `MontyProgress` directly from `_ProgressResponse.progress`
- `packages/dart_monty_native/lib/src/monty_native.dart` — remove `.result` / `.progress` unwrapping in `run()`, `start()`, `resume()`, `resumeWithError()`, etc.
- `packages/dart_monty_native/test/monty_native_test.dart` — update `MockNativeIsolateBindings` (or the test mock file) to return `MontyResult`/`MontyProgress` directly instead of wrappers. Update test setup accordingly.
- `packages/dart_monty_native/test/mock_native_isolate_bindings.dart` — update mock to match new `NativeIsolateBindings` signatures.

### Acceptance Criteria

- [ ] `NativeRunResult` class is deleted
- [ ] `NativeProgressResult` class is deleted
- [ ] `NativeIsolateBindings` abstract methods return domain types directly
- [ ] `NativeIsolateBindingsImpl` returns domain types directly (no wrapper construction)
- [ ] `MontyNative` does not unwrap `.result` / `.progress`
- [ ] All desktop tests pass (behavioral parity)
- [ ] Verify `MontyResult` and `MontyProgress` pass safely across the `SendPort`/`ReceivePort` boundary without serialization errors
- [ ] `dart analyze --fatal-infos` and `dart test` pass for `dart_monty_native`

### Gate

```bash
cd packages/dart_monty_native && dart analyze --fatal-infos && dart test
```

---

## Slice 11: Full-Stack Verification and Cleanup

**Commit:** 4
**Depends on:** Slice 10

### Goal

Run all gate scripts to verify full-stack behavioral parity. Clean up any
dead imports, unused exports, or stale references. Verify ladder parity
across backends.

### Files Changed

- `packages/dart_monty_platform_interface/lib/dart_monty_platform_interface.dart` — verify all new exports are present and ordered.
- `packages/dart_monty_ffi/lib/dart_monty_ffi.dart` — verify exports include `ffi_core_bindings.dart`.
- `packages/dart_monty_wasm/lib/dart_monty_wasm.dart` — verify exports include `wasm_core_bindings.dart`.
- Any files with dead imports — clean up.

### Acceptance Criteria

- [ ] `bash tool/test_platform_interface.sh` passes
- [ ] `bash tool/test_ffi.sh` passes (or skips cleanly if no cargo)
- [ ] `bash tool/test_wasm.sh` passes (or skips cleanly if no WASM toolchain)
- [ ] `python3 tool/analyze_packages.py` reports zero issues
- [ ] `dart format .` produces no changes
- [ ] No dead imports or unused exports remain
- [ ] All new files have dartdoc comments

### Gate

```bash
bash tool/gate.sh --dart-only
```

---

## Dependency Graph

```text
Slice 1 (capability interfaces — additive)
  |
  v
Slice 2 (slim MontyPlatform + all impls — atomic)
  |
  v
Slice 3 (mock + ladder runner)
  |
  v
Slice 4 (MontyCoreBindings types)
  |
  +--> Slice 5 (BaseMontyPlatform)
  +--> Slice 6 (FfiCoreBindings)
  +--> Slice 7 (WasmCoreBindings)
         |           |
         v           v
       Slice 8     Slice 9
       (MontyFfi)  (MontyWasm)
         |           |
         +-----+-----+
               |
               v
             Slice 10 (Desktop wrappers)
               |
               v
             Slice 11 (Verification)
```

## Commit Mapping

| Commit | Slices | Theme |
|--------|--------|-------|
| **1** | 1-3 | Capability interfaces + slim `MontyPlatform` |
| **2** | 4-7 | `MontyCoreBindings` + `BaseMontyPlatform` + adapters |
| **3** | 8-9 | Migrate `MontyFfi` + `MontyWasm` to `BaseMontyPlatform` |
| **4** | 10-11 | Desktop wrapper removal + full-stack verification |

---

## Deferred

Items identified during architecture analysis but out-of-scope for this
refactoring:

- **Arena-based FFI memory safety** (arch-analysis section 3.4) — deferred
  because `NativeBindingsFfi` is explicitly untouched in this refactoring.
  Address when `NativeBindingsFfi` is next modified.
