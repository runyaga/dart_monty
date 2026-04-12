# Test Audit -- Batch 4: WASM Tests + Top-Level + Helpers

**Auditor:** Claude Opus 4.6
**Date:** 2026-04-11
**Files audited:** 14

---

## Summary

| # | File | Type | Lines | Verdict |
|---|------|------|------:|---------|
| 1 | `test/wasm/monty_wasm_test.dart` | Unit test | 1055 | Solid |
| 2 | `test/wasm/wasm_core_bindings_test.dart` | Unit test | 500 | Solid |
| 3 | `test/wasm/mock_wasm_bindings.dart` | Helper (mock) | 332 | Healthy helper |
| 4 | `test/wasm/integration/python_ladder_runner.dart` | Runner (not a test) | 443 | Flag: standalone runner |
| 5 | `test/wasm/integration/repl_ladder_runner.dart` | Runner (not a test) | 249 | Flag: standalone runner |
| 6 | `test/wasm/integration/repl_session_demo.dart` | Demo (not a test) | 212 | Flag: demo/playground |
| 7 | `test/wasm/integration/repl_smoke_runner.dart` | Runner (not a test) | 198 | Flag: standalone runner |
| 8 | `test/wasm/integration/smoke_runner.dart` | Runner (not a test) | 206 | Flag: standalone runner |
| 9 | `test/wasm/integration/vfs_demo.dart` | Demo (not a test) | 278 | Flag: demo/playground |
| 10 | `test/wasm/integration/vfs_runner.dart` | Runner (not a test) | 276 | Flag: standalone runner |
| 11 | `test/ffi/mock_native_bindings.dart` | Helper (mock) | 339 | Healthy helper |
| 12 | `test/ffi/mock_native_isolate_bindings.dart` | Helper (mock) | 241 | Healthy helper |
| 13 | `test/ffi/integration/python_ladder_runner.dart` | Runner (not a test) | 192 | Flag: standalone runner |
| 14 | `test/monty_test.dart` | Unit test | 116 | Has hollow test |

---

## File-by-File Findings

### 1. `test/wasm/monty_wasm_test.dart` (1055 lines)

**Hollowness:** None. Every test has meaningful assertions on return values, state transitions, error types, and mock call tracking. Comprehensive coverage of `run()`, `start()`, `resume()`, `resumeWithError()`, `snapshot()`, `restore()`, `dispose()`, `MontyFutureCapable`, `os_call`, and `resolve_futures` states. Edge cases are well covered: null values, null arguments, null function names, partial limits merging with defaults, and data model fidelity (kwargs, callId, methodCall, excType, traceback).

**Quality:** Excellent. Proper setUp/tearDown lifecycle. Tests both happy paths and error paths for every operation. State machine correctness is validated (throws StateError when disposed, when active, when idle as appropriate). The `@Tags(['browser'])` annotation correctly marks this as browser-only.

**Consolidation:** No overlap with other files. This is the WASM counterpart to `test/ffi/monty_ffi_test.dart` -- parallel structure is appropriate since they test different backends.

**Verdict:** Keep as-is.

---

### 2. `test/wasm/wasm_core_bindings_test.dart` (500 lines)

**Hollowness:** None. Tests the `WasmCoreBindings` adapter layer which translates raw `WasmBindings` results into `CoreRunResult`/`CoreProgressResult`. Every test verifies field translation, state mapping, default handling, and timing injection.

**Quality:** Excellent. Covers init idempotency, all progress states (complete, pending, error, resolve_futures, os_call, unknown), panic detection and session invalidation (D-1, D-2 contract tests), printOutput forwarding, null field defaults, dispose lifecycle. The panic session-invalidation tests are particularly valuable -- they verify that after a `MontyPanicError`, `init()` re-creates the session.

**Consolidation:** No overlap. Correct layering test (WasmCoreBindings wraps WasmBindings).

**Verdict:** Keep as-is.

---

### 3. `test/wasm/mock_wasm_bindings.dart` (332 lines)

**Type:** Helper (mock) -- not a test file.

**Quality:** Well-structured hand-written mock with configurable return values (`next*` fields), throw-on-call support (`throwOn*` fields), and call tracking lists. Covers all `WasmBindings` methods including REPL operations. Used by both `monty_wasm_test.dart` and `wasm_core_bindings_test.dart` (2 consumers).

**Observation:** Several `throwOn*` fields are defined but never used in any test (`throwOnRun`, `throwOnStart`, `throwOnResume`, `throwOnResumeWithError`, `throwOnResumeAsFuture`, `throwOnResolveFutures`). These represent dead mock configuration. Not harmful, but could be pruned if no future tests are planned for them.

**Verdict:** Healthy helper. Keep. Optionally prune unused `throwOn*` fields.

---

### 4. `test/wasm/integration/python_ladder_runner.dart` (443 lines)

**Type:** Standalone JS-compiled runner -- NOT a `package:test` file. Compiled to JS and run in headless Chrome with COOP/COEP headers. Fetches fixture JSON over HTTP, drives `DartMontyBridge` via `@JS()` interop, outputs JSONL results.

**Quality:** Well-implemented. Handles all fixture types: simple run, expectError, iterative (start/resume), async futures (resumeAsFuture/resolveFutures), osCall with full VFS dispatch (memory/readonly/overlay modes). xfail/xpass logic is correct. Error handling is thorough with LADDER_ERROR/LADDER_STACKTRACE output.

**WASM vs FFI Duplication:** The FFI equivalent (`test/ffi/integration/python_ladder_runner.dart`, 192 lines) serves the same purpose but is much simpler -- it uses `MontyFfi` directly with synchronous bindings rather than JS interop. The logic overlap is structural (both drive fixtures through a start/resume loop), but the implementation is necessarily different due to the WASM browser environment. **Not a consolidation candidate** -- the WASM runner must use JS interop and HTTP fixture fetching.

**Flag:** Not a test. This is CI infrastructure that must be compiled to JS before execution. Consider documenting this in a README or CONTRIBUTING note.

---

### 5. `test/wasm/integration/repl_ladder_runner.dart` (249 lines)

**Type:** Standalone JS-compiled runner -- NOT a `package:test` file.

**Quality:** Good. Drives REPL ladder fixtures (feed sequences, continuation detection) through `DartMontyBridge` JS interop. Creates fresh REPL per fixture, handles both `feeds` and `continuation` fixture types. Pass/fail counting with LADDER_SUMMARY output.

**Observation:** The pass/fail counter logic on lines 238-239 is slightly incorrect -- it increments `passed++` in the try block before knowing whether the inner `_result()` call reported pass or fail. The LADDER_RESULT output is the authoritative result, but the summary counts may overcount passes.

**Flag:** Not a test. No FFI equivalent (REPL ladder is WASM-only in this codebase).

---

### 6. `test/wasm/integration/repl_session_demo.dart` (212 lines)

**Type:** Interactive demo/playground -- NOT a test file. Compiles to JS and exposes `window.ReplSessionDemo` API to HTML. Creates a `ReplSession` with `DinjaTemplatePlugin`, `MessageBusPlugin`, and `SandboxPlugin` for interactive browser use.

**Quality:** Well-structured demo. Clean API surface (run, execute, reset). Proper event-to-JSON mapping for `BridgeEvent` types.

**Flag:** This is a demo, not a test or runner. It has no assertions and no pass/fail output. It depends on an HTML harness. Consider moving to `example/` or `tool/` rather than living under `test/`.

---

### 7. `test/wasm/integration/repl_smoke_runner.dart` (198 lines)

**Type:** Standalone JS-compiled runner -- NOT a `package:test` file.

**Quality:** Good. Five focused smoke tests for WASM REPL: variable persistence, function persistence, error recovery, continuation detection, and 50-iteration stress test. Clean SMOKE_PASS/SMOKE_FAIL output.

**Observation:** No FFI equivalent. FFI REPL smoke tests live in `test/ffi/integration/repl_smoke_test.dart` (a proper `package:test` file, 9.5k). The WASM version cannot use `package:test` because it must compile to JS and run in a browser with SharedArrayBuffer headers. Not a consolidation candidate.

**Flag:** Not a test.

---

### 8. `test/wasm/integration/smoke_runner.dart` (206 lines)

**Type:** Standalone JS-compiled runner -- NOT a `package:test` file.

**Quality:** Good. Six smoke tests: simple run, string result, error handling, iterative start/resume, resumeWithError, and snapshot/restore. Clean SMOKE_PASS/SMOKE_FAIL output. The snapshot test gracefully handles the known Node.js Buffer limitation in browsers.

**Observation:** Stale build comment on line 9 says `test/integration/smoke_test.dart` but the file is at `test/wasm/integration/smoke_runner.dart`. Minor documentation drift.

**Flag:** Not a test. Has an FFI counterpart at `test/ffi/integration/smoke_test.dart` (proper test file). Not a consolidation candidate due to different runtime requirements.

---

### 9. `test/wasm/integration/vfs_demo.dart` (278 lines)

**Type:** Interactive demo/playground -- NOT a test file. Compiles to JS, exposes `window.VfsDemo` with `run`, `mountFile`, `clearMounts` API. Uses static `DartMontyBridge.*` JS interop.

**Quality:** Functional but has a latent bug: `_listDir()` on line 230 calls `_vfs.resolve()` (which returns a `Future`) and then tries to use `then()` to populate a local list synchronously, but returns the list before the future completes. The list will always be empty. This means `_collectFiles()` never discovers any files. This is a demo, not a test, so it does not affect test correctness, but the VFS file tree in the UI response will always be empty.

**Flag:** Demo, not a test. Same recommendation as `repl_session_demo.dart` -- consider moving to `example/` or `tool/`. The `_listDir` bug should be fixed if this demo is still in use.

---

### 10. `test/wasm/integration/vfs_runner.dart` (276 lines)

**Type:** Standalone JS-compiled runner -- NOT a `package:test` file.

**Quality:** Good. Five focused VFS tests: write/read round-trip, Path.exists on missing file, mkdir+iterdir, JSON config read/parse, and a data pipeline test that reads CSV, processes it, writes output, and verifies from both Python and Dart sides. Uses instance-based `_DartMontyBridge` (unlike the static interop in other runners).

**Observation:** Uses instance-based `_DartMontyBridge()` interop pattern (line 25-31) while other runners use static `@JS('DartMontyBridge.xxx')`. This inconsistency is not wrong but is worth noting -- it depends on which pattern the bridge JS actually exports. No equivalent FFI VFS runner exists.

**Flag:** Not a test.

---

### 11. `test/ffi/mock_native_bindings.dart` (339 lines)

**Type:** Helper (mock) -- not a test file.

**Quality:** Well-structured hand-written mock for `NativeBindings`. Configurable return values, call tracking, queue-based resume/resumeWithError results. Covers all methods including REPL operations (create, free, feedRun, detectContinuation, feedStart, resume, resumeWithError, resumeAsFuture, resolveFutures).

**Consumers:** 5 files import this: `monty_ffi_test.dart`, `ffi_core_bindings_test.dart`, `repl_platform_test.dart`, `monty_repl_test.dart`, `repl_session_unit_test.dart`. Widely used and essential.

**Observation:** The `_defaultCompleteJson` constant is repeated as an inline string in 6 places within the file. Could extract to a single constant (already partially done with the top-level `_defaultCompleteJson`, but the REPL methods define their own inline copies). Minor DRY concern.

**Verdict:** Healthy helper. Keep.

---

### 12. `test/ffi/mock_native_isolate_bindings.dart` (241 lines)

**Type:** Helper (mock) -- not a test file.

**Quality:** Well-structured hand-written mock for `NativeIsolateBindings`. Works at the higher `MontyResult`/`MontyProgress` level (not raw JSON like `MockNativeBindings`). Supports `runGate` completer for concurrency testing. Queue-based results for resume operations.

**Consumers:** 1 file imports this: `test/ffi/monty_native_test.dart`. Single consumer.

**Observation:** Only one consumer. If `monty_native_test.dart` were ever removed or refactored, this mock becomes orphaned. The `throwOnStart` and `throwOnResume` fields are typed as `Object?` (not `Exception?`) to allow testing with arbitrary throwables -- this is intentional and documented.

**Verdict:** Healthy helper. Keep.

---

### 13. `test/ffi/integration/python_ladder_runner.dart` (192 lines)

**Type:** Standalone CLI runner -- NOT a `package:test` file. Runs with `dart test/ffi/integration/python_ladder_runner.dart` directly, outputs JSONL.

**Quality:** Good. Drives all fixture tiers through `MontyFfi` with `NativeBindingsFfi`. Handles simple, expectError, iterative, and osCall fixture types. Uses `defaultSandboxOs()` for OS call dispatch.

**Observation:** There is a proper `package:test` wrapper at `test/ffi/integration/python_ladder_test.dart` (32 lines) that uses `registerLadderTests()` -- making this standalone runner a secondary/alternative way to run the same fixtures. The runner is useful for manual debugging (JSONL output) but is redundant with the test-framework version for CI.

**Missing:** Unlike the WASM ladder runner, this FFI version does not handle `asyncResumeMap`/`asyncErrorMap` (async futures fixtures). If async fixtures exist in the tier files, they would fail silently or error.

**Flag:** Not a test. Partially redundant with `python_ladder_test.dart`. May be missing async fixture support.

---

### 14. `test/monty_test.dart` (116 lines)

**Hollowness:** **One hollow test.** The `Monty.exec()` group (lines 109-114) contains a single test with an empty body and a comment: "Can't easily test with mock since exec() creates its own Monty." This is a genuinely hollow test -- it is recognized by `dart test` as a test case, always passes, and tests nothing.

**Quality:** The non-hollow tests are good. Tests the `Monty` wrapper class: platform getter, run() delegation, limits/scriptName passthrough, state persistence across runs, clearState(), start/resume via platform, and dispose(). Uses `MockMontyPlatform` with the `enqueueRunCycle` helper pattern that matches MontySession's internal restore/persist protocol.

**Overlap:** Significant overlap with `test/platform/monty_session_test.dart` which tests `MontySession` directly. The `Monty` class is a thin wrapper around `MontySession` + `MontyPlatform`, so `monty_test.dart` is effectively re-testing `MontySession` behavior through the `Monty` facade. This is acceptable as a "does the wiring work" test, but the variable persistence test (line 69-76) and run delegation test (line 48-52) duplicate what `monty_session_test.dart` already covers more thoroughly.

**Verdict:** Remove or implement the hollow `Monty.exec()` test. The `exec()` method is simple (create, run, dispose) and could be tested by mocking `createPlatformMonty` or by using the existing `MockMontyPlatform` with `Monty.withPlatform`.

---

## Cross-Cutting Findings

### A. WASM Integration Files Are All Runners/Demos, Not Tests

All 7 files under `test/wasm/integration/` are standalone executables, not `package:test` files:
- **Runners** (5): `python_ladder_runner.dart`, `repl_ladder_runner.dart`, `repl_smoke_runner.dart`, `smoke_runner.dart`, `vfs_runner.dart` -- compiled to JS, run in headless Chrome, output structured text (LADDER_RESULT/SMOKE_PASS/VFS_PASS)
- **Demos** (2): `repl_session_demo.dart`, `vfs_demo.dart` -- compiled to JS, expose browser APIs for interactive use

These cannot be `package:test` files because they require:
1. Compilation to JS via `dart compile js`
2. Headless Chrome with COOP/COEP headers (SharedArrayBuffer requirement)
3. An HTTP server to serve fixtures and WASM artifacts

This is a legitimate constraint of WASM testing. However, having them under `test/` is misleading. Consider:
- Moving demos to `example/wasm/` or `tool/wasm_demo/`
- Adding a `test/wasm/integration/README.md` that explains the runner/demo distinction and build instructions

### B. WASM vs FFI Ladder Runner Duplication

The `python_ladder_runner.dart` files exist in both `test/wasm/integration/` and `test/ffi/integration/`. They share the same conceptual flow (load fixtures, dispatch by type, drive start/resume loop) but differ substantially in implementation:
- WASM: JS interop, HTTP fixture fetching, JSONL text output, handles os_call/async natively
- FFI: Direct `MontyFfi` API, filesystem fixture loading, stdout JSONL

**Not a consolidation candidate.** The runtime environments are fundamentally different. The FFI version also has a proper `package:test` wrapper (`python_ladder_test.dart`) which the WASM version cannot have.

### C. Mock Files Are Healthy

All three mock files (`mock_wasm_bindings.dart`, `mock_native_bindings.dart`, `mock_native_isolate_bindings.dart`) are well-structured, have active consumers, and follow consistent patterns. They are hand-written rather than using `mockito`/`mocktail`, which is appropriate for this API surface (configurable returns + call tracking is cleaner than verify-style mocking for these bindings).

### D. Unused Mock Configuration Fields

`MockWasmBindings` has 6 `throwOn*` fields that are never referenced in any test file:
- `throwOnRun`
- `throwOnStart`
- `throwOnResume`
- `throwOnResumeWithError`
- `throwOnResumeAsFuture`
- `throwOnResolveFutures`

These were likely added for future use but represent dead code. Low priority to clean up.

---

## Action Items

| Priority | Action | Files |
|----------|--------|-------|
| **High** | Remove or implement hollow `Monty.exec()` test (empty body, always passes) | `test/monty_test.dart:109-114` |
| **Medium** | Fix `_listDir` async bug in VFS demo (Future.then result ignored, list always empty) | `test/wasm/integration/vfs_demo.dart:230-245` |
| **Medium** | Add async fixture support to FFI ladder runner (missing `asyncResumeMap`/`asyncErrorMap` handling) | `test/ffi/integration/python_ladder_runner.dart` |
| **Low** | Fix stale build comment referencing wrong path | `test/wasm/integration/smoke_runner.dart:9` |
| **Low** | Fix pass/fail counter bug in REPL ladder runner | `test/wasm/integration/repl_ladder_runner.dart:238-239` |
| **Low** | Prune 6 unused `throwOn*` fields from `MockWasmBindings` | `test/wasm/mock_wasm_bindings.dart` |
| **Low** | DRY up repeated `_defaultCompleteJson` strings in MockNativeBindings | `test/ffi/mock_native_bindings.dart` |
| **Low** | Consider moving demo files out of `test/` into `example/` or `tool/` | `vfs_demo.dart`, `repl_session_demo.dart` |
| **Low** | Add `README.md` to `test/wasm/integration/` explaining runner vs demo vs test distinction | (new file) |
