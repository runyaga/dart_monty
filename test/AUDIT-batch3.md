# Test Audit -- Batch 3: Remaining Integration Tests + REPL Tests

**Auditor:** Claude Opus 4.6 (1M context)
**Date:** 2026-04-11
**Files audited:** 20
**Scope:** test/bridge/integration/ (remaining), test/ffi/, test/ffi/integration/, test/repl/

---

## File-by-File Findings

### 1. sandbox_logging_test.dart (155 lines, integration)

**Hollowness:** None. Every test verifies specific structured log records, messages, levels, and attributes.

**Quality:** Covers:
- Full spawn+await lifecycle logging (Child bridge created, Child spawned, Child completed)
- Structured attributes on spawn record (childId, depth)
- Failed child error logging (level, childId, error message contains NameError)
- Dispose logging (level, totalChildren, aliveChildren counts)

**Gaps:**
- No test for log records when child is freed via sandbox_free (as opposed to dispose).

**Verdict:** Solid. Focused on its specific concern (structured logging).

---

### 2. sandbox_plugin_inheritance_test.dart (414 lines, integration)

**Hollowness:** None. Every test executes real Python code through FFI and verifies return values, error propagation, and instance isolation.

**Quality:** Excellent. Covers:
- Baseline: child sandbox computes and returns value, captures print output
- createChildInstance: parent calls inherited function, child inherits via createChildInstance, child without inheritable plugins errors, multiple children get independent instances (counter isolation, parent untouched)
- childPluginRegistryFactory: factory takes precedence over parentPlugins (empty registry overrides)
- ChildSpawnContext: child receives context with workingDirectory, null workingDirectory when sandboxBaseDir unset

**Notable:** The `_syncChild` helper at line 12 is declared but its usage at lines 140, 160, 191, 235 is essentially pass-through (`_syncChild(expr)` returns `expr`). The helper adds no value and obscures what's happening.

**Gaps:**
- `_syncChild` is a no-op function that adds confusion. Should be removed and callers should use string literals directly.

**Verdict:** High quality. Minor cleanup: remove dead `_syncChild` helper.

---

### 3. sandbox_plugin_reg_failure_test.dart (132 lines, integration)

**Hollowness:** None. Tests verify specific error log records with phase attributes.

**Quality:** Covers:
- Factory failure: logs phase=factory, error level
- attachTo failure: logs phase=attachTo, pluginCount attribute, error level

**Notable:** Clean, focused test file. The `_IntegrationBoomPlugin` helper is well-constructed for its purpose.

**Verdict:** Good quality. No action needed.

---

### 4. ffi_async_host_fn_test.dart (359 lines, integration)

**Hollowness:** None. Every test registers a host function with real async I/O and verifies two sequential calls succeed (regression for #271 SEGFAULT).

**Quality:** Thorough regression coverage for #271. Covers:
- Sync host function -- two sequential calls
- Async with 100ms delay -- two calls
- Async with 1s delay -- two calls
- Real HTTP GET -- two calls (shared mode)
- Real HTTP GET -- two calls (sandbox mode)
- File I/O -- two calls
- Process I/O -- two calls
- Socket listen -- two calls
- HTTP returning status code only -- two calls
- HTTP returning large body -- two calls

**Issue: EXTERNAL NETWORK DEPENDENCY.** Tests at lines 92-139, 142-188, 267-310, 312-357 hit `https://demo.toughserv.com/api/v1/installation/versions`. This makes tests fail when:
- Offline / no internet
- demo.toughserv.com is down
- Running in CI without network access

This same issue affects files #5, #6, #7, #8, #9 in this batch. All 6 files hardcode the same external URL.

**Verdict:** Good regression test battery. The external URL dependency is a systemic concern across 6 files (addressed in consolidation section).

---

### 5. ffi_finalizer_race_test.dart (136 lines, integration)

**Hollowness:** None. Tests create/dispose many sessions and verify subsequent sessions work.

**Quality:** Covers:
- Create/dispose 5 sessions, then HTTP on 6th
- Create/dispose 10 sessions with HTTP each
- Interleaved sync and HTTP sessions
- Rapid create/dispose without execute (GC pressure)
- Sandbox mode: 10 execute calls with HTTP

**Overlap with #4:** Both files test sequential HTTP calls through AgentSession. The distinction is that #4 isolates async-host-fn patterns while #5 isolates finalizer/GC race conditions. The overlap is in HTTP host function setup boilerplate (identical `_httpFn()` and `_syncFn()` factories appear in both files).

**Verdict:** Good regression test. Shares boilerplate with #4 and #7.

---

### 6. ffi_mixed_mode_test.dart (474 lines, integration)

**Hollowness:** None. Extensive behavioral assertions on every execute call.

**Quality:** Very thorough. Covers:
- G. Shared mode stress: 20 sync calls, 10 delay calls, 10 HTTP calls, counter state persistence, accum state persistence, list accumulation across 10 calls, error recovery (bad call then good), error recovery after HTTP
- H. Plugin combos: Template across 5 calls, MessageBus across calls, FS+Template, HTTP+Template+MsgBus, HTTP+counter, FS+HTTP+KV across calls
- I. Edge cases: empty execute (pass), comments only, large string (100K), large list (1000), nested dict, host fn returning None, host fn returning 50KB string, host fn exception propagation, print capture, multiple prints across calls

**Overlap with #7:** Groups G, H, and I overlap significantly with the plugin matrix test. In particular:
- G1-G8 (shared mode stress) are a superset of what ffi_plugin_matrix_test.dart covers in sections A and B
- I1-I10 (edge cases) duplicate section F of ffi_plugin_matrix_test.dart nearly identically
- H1-H6 (plugin combos) overlap sections C and D of ffi_plugin_matrix_test.dart

**Verdict: MAJOR CONSOLIDATION OPPORTUNITY** with ffi_plugin_matrix_test.dart. See consolidation section.

---

### 7. ffi_plugin_matrix_test.dart (335 lines, integration)

**Hollowness:** None. All 25+ experiments have assertions.

**Quality:** Comprehensive single-session test covering:
- A. Single execute, N host calls (sync x10, delay x5, HTTP x3, mixed, KV)
- B. State persistence (sync, HTTP, list accumulation, error recovery)
- C. Plugin combinations (sync+kv+delay, sync+kv+HTTP, all 5 fns)
- D. Built-in plugins (template, msgbus, template+msgbus+sync, template+msgbus+http, ALL plugins+fns)
- E. Filesystem (write+read, http->fs, fs+template+msgbus+http)
- F. Edge cases (large string, large list, nested dict, print capture, HTTP x5 loop)

**Design note:** Intentionally runs as ONE test to avoid zone contamination (documented in file header). This architectural constraint is valid for FFI integration tests.

**Overlap with #6:** As noted above, ffi_mixed_mode_test.dart duplicates most of this file's coverage in a multi-test format. The matrix test is the more disciplined version (single session, all in one test).

**Verdict:** Good. See consolidation recommendation with #6.

---

### 8. ffi_raw_bridge_http_test.dart (116 lines, integration)

**Hollowness:** None. Tests real HTTP through 3 different API layers.

**Quality:** Covers:
- DefaultMontyBridge.execute -- 3 sequential HTTP calls
- Monty.run -- 3 sequential HTTP calls
- AgentSession shared mode -- 3 sequential HTTP calls
- AgentSession sandbox mode -- 3 sequential HTTP calls

**Purpose:** Isolates HTTP failures to specific API layers. If AgentSession fails but DefaultMontyBridge succeeds, the bug is in the state wrapping layer.

**Overlap with #4, #9:** All three files test sequential HTTP calls through AgentSession. This file uniquely tests lower-level APIs (DefaultMontyBridge, Monty.run).

**Verdict:** Good diagnostic test. The lower-level API tests are unique. The AgentSession tests overlap with other files.

---

### 9. ffi_single_session_http_test.dart (131 lines, integration)

**Hollowness:** None. All 5 tests make real HTTP calls and verify results.

**Quality:** Covers:
- Single persistent session making multiple HTTP calls (1 through 4)
- State persistence across HTTP calls
- 5 sequential HTTP calls in one execute

**Overlap:** This is a strict subset of what ffi_mixed_mode_test.dart G3 and ffi_plugin_matrix_test.dart A3/F5 already cover. The "single long-lived session" angle is the only distinguishing factor, but the matrix test already uses a single session.

**Verdict: CONSOLIDATION CANDIDATE.** This file can be removed -- its scenario is fully covered by ffi_plugin_matrix_test.dart (which is also a single long-lived session with HTTP calls).

---

### 10. ffi_core_bindings_finalizer_test.dart (92 lines)

**Hollowness:** None. Tests verify handle survival after GC pressure.

**Quality:** Covers:
- 20 create/start/free cycles then one execute (with forced GC via NativeRuntime.writeHeapSnapshotToFile)
- Dispose does not leave dangling finalizer (s1 dispose, s2 survives GC)
- 100 rapid session cycles

**Notable:** NOT tagged as integration despite using AgentSession with real FFI. The file lacks `@Tags(['integration'])` annotation. This means it runs in the default test suite where FFI may not be available.

**Verdict:** Good regression test for #271. **Fix missing `@Tags(['integration'])` annotation.**

---

### 11. python_ladder_test.dart (31 lines, integration+ladder)

**Hollowness:** None. This is a thin entry point that delegates to `registerLadderTests` from `dart_monty_testing.dart`.

**Quality:** Correctly wires FFI bindings and fixture directory. The actual test logic lives in `lib/src/platform/testing/ladder_runner.dart`.

**Verdict:** Proper pattern. No issues.

---

### 12. smoke_test.dart (123 lines, integration)

**Hollowness:** None. Every test exercises real FFI operations and verifies results.

**Quality:** Core FFI smoke tests. Covers:
- Simple run("2+2") returns 4 with resource usage
- Iterative: start with ext fn, resume, complete
- resumeWithError: error propagation
- Error handling: invalid syntax
- Dispose safety: double dispose
- UTF-8 boundaries: emoji round-trip
- Multiple instances: no state bleed
- Memory stability: 100-iteration loop

**Verdict:** Essential smoke test suite. High quality. No action needed.

---

### 13. readme_doctest.dart (535 lines, integration)

**Hollowness:** None. Every handler executes real code or validates structure.

**Quality:** Excellent approach -- extracts fenced dart blocks from README.md files and validates them. Covers:
- Root README: run + limits, external function dispatch, stateful sessions
- platform_interface README: MontyResult.fromJson
- ffi README: MontyFfi run + dispatch
- wasm/web/native READMEs: structure validation
- Example files: ffi (full exercise), platform_interface (type construction), wasm/web/native/root (structure)

**Notable:** The safety net at line 286-295 ensures every dart block in every README has a handler -- new examples without handlers cause test failures. This is a disciplined approach to documentation testing.

**Verdict:** High quality. No action needed.

---

### 14. repl_ladder_test.dart (28 lines, integration+repl-ladder)

**Hollowness:** None. Thin entry point delegating to `registerReplLadderTests`.

**Quality:** Correctly wires FFI bindings and fixture directory.

**Verdict:** Proper pattern. No issues.

---

### 15. repl_smoke_test.dart (334 lines, integration)

**Hollowness:** None. Every test exercises the REPL through real FFI.

**Quality:** Comprehensive. Covers:
- State persistence: variable, function definition, list mutation, closure
- Error recovery: survives runtime error, state preserved after error
- help() system: list functions, detail, unknown function
- Print output: captured per-feed
- Multiple sessions: independent state
- 50-iteration stability
- detectContinuation: complete, incompleteBlock, incompleteImplicit
- feedStart/resume: pauses at ext fn, state persists after cycle, multiple ext fn calls, resumeWithError, feed works after feedStart cycle

**Verdict:** Strong integration test suite. No action needed.

---

### 16. monty_repl_test.dart (161 lines, unit)

**Hollowness:** None. Tests use MockNativeBindings to verify REPL behavior without FFI.

**Quality:** Covers:
- feed creates REPL on first call
- feed does not recreate on subsequent calls (verifies bootstrap feed count)
- detectContinuation returns correct mode
- dispose frees REPL handle
- feed after dispose throws
- feed returns print output
- feed with error returns MontyResult with error

Also covers FfiReplBindings:
- feedRun before create throws StateError
- translateRunResult parses ok/error results

Also covers ReplContinuationMode enum values.

**Verdict:** Good unit coverage with mocks. Complements the integration tests in repl_smoke_test.dart (#15).

---

### 17. repl_platform_test.dart (86 lines, unit)

**Hollowness:** None. Tests verify delegation from ReplPlatform to MontyRepl.

**Quality:** Covers:
- run delegates to feed
- start delegates to feedStart
- resume delegates to repl resume
- resumeWithError delegates

**Verdict:** Clean delegation tests. No issues.

---

### 18. repl_session_test.dart (287 lines, integration)

**Hollowness:** None. Real FFI integration tests for ReplSession.

**Quality:** Covers:
- Simple expression, state persistence, function persistence
- DinjaTemplatePlugin: tmpl_render, computed context, for loop
- execute() returns BridgeEvent stream
- Error does not kill session
- Template result stored and reused
- Dispose is idempotent
- SandboxPlugin integration: spawn+await, sandbox result feeds into template, sandbox_gather parallel, sandbox error propagation, grandchild (child spawns child)

**Notable:** NOT tagged as `@Tags(['integration'])` despite requiring real FFI. Same issue as file #10.

**Overlap with repl_sse_test.dart (#20):** Both files test ReplSession with DinjaTemplatePlugin. repl_session_test.dart focuses on core REPL+plugin behavior; repl_sse_test.dart focuses on multi-turn streaming scenarios.

**Verdict:** Good integration coverage. **Fix missing `@Tags(['integration'])` annotation.**

---

### 19. repl_session_unit_test.dart (51 lines, unit)

**Hollowness: MEDIUM.**
- Lines 15-19: "construction does not throw" -- only checks `isNotNull`. The constructor either works or it doesn't; this is Dart type system verification.
- Lines 21-26: "dispose is idempotent" -- same test exists in repl_session_test.dart (#18, line 144). Exact duplicate.
- Lines 40-49: "withRepl accepts plugins" -- only checks `isNotNull` after passing an empty list. Tests Dart argument passing.

**Quality:** Only 4 tests, 3 of which are trivial. The "dispose after use" test (lines 28-38) has marginal value -- it triggers creation then disposes.

**Verdict: LOW VALUE.** This file can be deleted. The only non-trivial test (dispose after use) is already covered by repl_session_test.dart which tests dispose idempotency and error recovery with real FFI.

---

### 20. repl_sse_test.dart (121 lines, integration)

**Hollowness:** None. All tests verify specific event types, values, and multi-turn state.

**Quality:** Covers:
- Multi-turn: 10 sequential execute() calls with tmpl_render
- State persists across 20 stream executions (sum 1..20 = 210)
- Template + error + template recovery
- Interleave template and pure Python
- BridgeEvent stream has tool call events (RunStarted, ToolCallStart, ToolCallResult, RunFinished)
- 5 rapid stream executions back-to-back
- MessageBus across turns

**Notable:** NOT tagged as `@Tags(['integration'])` despite requiring real FFI. Same issue as files #10, #18. Wait -- line 2 shows `@Tags(['integration'])`. This one IS correctly tagged.

**Verdict:** Good multi-turn streaming coverage. No action needed.

---

## Summary

| Metric | Count |
|---|---|
| Total files audited | 20 |
| Hollow/low-value tests found | 1 file (repl_session_unit_test.dart -- 4 trivial tests) |
| Consolidation opportunities | 2 (major: FFI HTTP integration tests; minor: repl_session_unit_test.dart deletion) |
| Missing @Tags annotation | 2 files (ffi_core_bindings_finalizer_test.dart, repl_session_test.dart) |
| External network dependency | 6 files (all hit demo.toughserv.com) |
| Quality gaps identified | 3 minor |
| High-quality files (no action) | 14 |

---

## Prioritized Action Items

### P0: Fix missing @Tags(['integration']) annotations

**Files:**
- `test/ffi/ffi_core_bindings_finalizer_test.dart` (#10) -- uses AgentSession with real FFI but has no integration tag
- `test/repl/repl_session_test.dart` (#18) -- uses ReplSession with real FFI, SandboxPlugin with MontyFfi() but has no integration tag

**Impact:** Without the tag, these tests run in the default `dart test` suite where native libraries may not be loaded. They will fail in CI environments that only run unit tests.

**Action:** Add `@Tags(['integration'])` and `library;` directive to both files.

### P1: Consolidate FFI HTTP integration tests

**Problem:** Six files in `test/bridge/integration/` all test sequential HTTP calls through AgentSession/MontyBridge with nearly identical host function factories and the same hardcoded external URL (`https://demo.toughserv.com/api/v1/installation/versions`):

| File | Unique angle | Overlapping coverage |
|---|---|---|
| ffi_async_host_fn_test.dart | Async I/O patterns (delay, file, process, socket) | HTTP two-call pattern |
| ffi_finalizer_race_test.dart | GC/finalizer race conditions | HTTP host fn factory |
| ffi_mixed_mode_test.dart | Multi-execute shared-mode stress, plugin combos, edge cases | Sections G3, H4-H6, I overlap with matrix |
| ffi_plugin_matrix_test.dart | All plugins in one session, 25 experiments | Canonical reference |
| ffi_raw_bridge_http_test.dart | Lower-level API layers (DefaultMontyBridge, Monty.run) | AgentSession HTTP tests |
| ffi_single_session_http_test.dart | Persistent session HTTP | Fully subsumed by matrix test |

**Action:**
1. **Delete ffi_single_session_http_test.dart** -- its coverage is a strict subset of ffi_plugin_matrix_test.dart (both use a single long-lived session with sequential HTTP calls).
2. **Remove duplicate edge case tests from ffi_mixed_mode_test.dart** -- Group I (I1-I10) duplicates section F of ffi_plugin_matrix_test.dart almost line-for-line. Remove group I entirely. Group G and H have enough unique multi-execute-call angles to justify keeping.
3. **Extract shared HTTP host function factory** -- All 6 files define nearly identical `_httpFn()` / `httpFn()` / `_httpGetFn()` factories. Extract to a shared test helper (e.g., `test/bridge/integration/_test_host_fns.dart`) and import from all files.
4. **Consider extracting the external URL to a constant** so it can be changed in one place if the endpoint moves.

**Impact:** Removes ~200 lines of duplicate code. Makes it clear which file tests which concern.

### P2: Delete repl_session_unit_test.dart

**File:** `test/repl/repl_session_unit_test.dart` (#19)

All 4 tests are either trivial (construction returns non-null, accepts empty plugins list) or duplicated (dispose idempotency). repl_session_test.dart already provides full integration coverage of ReplSession lifecycle.

**Action:** Delete the file.

**Impact:** Removes 51 lines of low-value tests.

### P3: Remove dead _syncChild helper

**File:** `test/bridge/integration/sandbox_plugin_inheritance_test.dart` (#2)

The `_syncChild` function at line 12 is a pass-through (`String _syncChild(String expr) => expr;`). It was presumably a placeholder for some transformation that never materialized. It's used at lines 140, 160, 191, 235 and adds confusion.

**Action:** Remove the function and inline its usages (replace `_syncChild(expr)` with `expr` at all call sites).

**Impact:** Removes misleading indirection.

### P4: External network dependency (systemic, low priority)

Six integration test files hardcode `https://demo.toughserv.com/api/v1/installation/versions`. This creates:
- Fragile tests that fail when offline or when the server is down
- CI environment concerns (network access required)

**Action (future):** Consider one of:
- A test-local HTTP server (e.g., `dart:io` HttpServer) that returns canned responses
- A `@Tags(['network'])` annotation so network-dependent tests can be skipped in restricted environments
- At minimum, extract the URL to a shared constant

**Impact:** Improves test reliability in offline/restricted environments.

### P5: Minor quality observations (no action required)

- **ffi_plugin_matrix_test.dart:** The single-test-with-25-experiments design is justified by the zone contamination issue but makes failure diagnosis harder (which of 25 experiments failed?). The `print()` statements help, but the test name won't indicate which experiment. This is an acceptable tradeoff.
- **repl_sse_test.dart:** File name says "SSE" but tests are about multi-turn streaming through ReplSession.execute(). The SSE connection to Server-Sent Events is not obvious -- consider renaming to `repl_multi_turn_test.dart` if SSE is not actually involved.
- **ffi_core_bindings_finalizer_test.dart:** Uses `developer.NativeRuntime.writeHeapSnapshotToFile('/dev/null')` to force GC. This is a Dart SDK API that may change. Document the dependency.

---

## Overall Assessment

This batch contains the project's integration test backbone. The FFI smoke tests (smoke_test.dart), REPL smoke tests (repl_smoke_test.dart), and readme doctests (readme_doctest.dart) are all high quality and well-structured. The ladder tests (python_ladder_test.dart, repl_ladder_test.dart) use a clean contract-runner pattern.

The main concern is the cluster of 6 HTTP-based integration tests in `test/bridge/integration/` that emerged from debugging issue #271. These files were clearly written incrementally during diagnosis -- each explores a slightly different angle -- but they now have substantial overlap. The plugin matrix test is the most comprehensive and disciplined of the group; the others should be trimmed to their unique contributions.

The REPL test stack (monty_repl_test.dart, repl_platform_test.dart, repl_session_test.dart, repl_smoke_test.dart, repl_sse_test.dart) has clean separation between unit tests (mock-based) and integration tests (real FFI), with no significant overlap.

Two files are missing `@Tags(['integration'])` annotations, which is the highest-priority fix as it affects test suite correctness.
