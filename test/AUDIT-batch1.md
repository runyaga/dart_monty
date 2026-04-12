# Test Audit -- Batch 1: Platform + FFI Unit Tests

**Auditor:** Claude Opus 4.6  
**Date:** 2026-04-11  
**Files audited:** 25  

---

## File-by-File Findings

### 1. `test/platform/monty_error_test.dart` (146 lines)

**Hollowness:** Low. Tests construction, toString, implements-Exception, pattern matching, and catch-as-supertype for all 5 sealed subtypes. The "catch as MontyError works for all subtypes" test (line 120-143) only asserts `isA<MontyError>()` -- this is trivially true by definition and adds no value beyond the pattern matching test above it.

**Quality:** Missing: equality/hashCode tests for error types (if they define them). No edge case tests for empty-string messages. No test for `MontyScriptError.exception` field (which exists on the class -- tested elsewhere but not here).

**Consolidation:** Significant overlap with `error_hierarchy_test.dart` (file #19). Both test the same sealed hierarchy, pattern matching, and catch ordering. **Merge candidate.**

---

### 2. `test/platform/monty_exception_test.dart` (371 lines)

**Hollowness:** None. Every test has meaningful assertions. Excellent coverage of fromJson, toJson, round-trip, equality across all fields, toString variants, edge cases (empty message, long message), and malformed JSON.

**Quality:** Thorough. Tests malformed JSON (missing message, wrong type). Tests all equality axes. Tests traceback with multiple frames. Only gap: no test for very large traceback (100+ frames), but that is minor.

**Consolidation:** Self-contained, no overlap.

---

### 3. `test/platform/monty_limits_test.dart` (178 lines)

**Hollowness:** None. Clean value-type tests.

**Quality:** Good. Tests all-null, partial, full, round-trip, equality, toString, malformed JSON. Missing: negative values for memoryBytes/timeoutMs/stackDepth (should those be rejected?). Missing: zero values as boundary cases.

**Consolidation:** Self-contained.

---

### 4. `test/platform/monty_platform_test.dart` (40 lines)

**Hollowness:** None. Concisely tests that the abstract `MontyPlatform` base class's default method implementations all throw `UnimplementedError`. This is exactly what the test should do.

**Quality:** Adequate. Does not test `resumeAsFuture()`, `resolveFutures()`, `snapshot()`, `restoreSnapshot()` if they exist on MontyPlatform -- may be stale if the API has grown. **Verify API surface matches.**

**Consolidation:** Self-contained. Could be merged into `base_monty_platform_test.dart` since both test platform base classes, but the separation is reasonable.

---

### 5. `test/platform/monty_progress_test.dart` (960 lines)

**Hollowness:** None. This is a thorough, high-quality test file covering MontyComplete, MontyPending, MontyOsCall, MontyResolveFutures, the `fromJson` discriminator, pattern matching, deep equality, nested collections, null safety, and malformed JSON. Every test has meaningful assertions.

**Quality:** Excellent. Tests edge cases systematically: null/empty arguments, kwargs null vs empty, callId defaults, methodCall defaults, nested maps/lists, unknown type discriminator. Malformed JSON section is good.

**Consolidation:** Self-contained. Large but well-organized by sealed subtype.

---

### 6. `test/platform/monty_resource_usage_test.dart` (156 lines)

**Hollowness:** None. Standard value-type test battery.

**Quality:** Good. Tests fromJson, toJson, round-trip, equality for each field, toString, malformed JSON. Missing: boundary values (zero, max-int, negative). The malformed JSON section could test more cases (e.g., missing individual fields).

**Consolidation:** Self-contained.

---

### 7. `test/platform/monty_result_test.dart` (266 lines)

**Hollowness:** None. Meaningful assertions throughout.

**Quality:** Good. Tests value/error paths, printOutput, null-without-error, equality across all axes, toString for each variant, malformed JSON. One minor gap: no test for `isError` when both value and error are present.

**Consolidation:** Self-contained.

---

### 8. `test/platform/monty_session_test.dart` (~500 lines)

**Hollowness:** None. Integration-style tests that exercise the session lifecycle (restore/persist/resume) using MockMontyPlatform. Every test has meaningful behavioral assertions.

**Quality:** Excellent. Tests: state persistence across runs, multiple types, non-serializable values dropped, code wrapping, internal function registration, unexpected-function rejection, MontyResolveFutures handling, session isolation, error-preserves-state, limits/scriptName forwarding, large state round-trip. One of the best-tested classes.

**Consolidation:** Self-contained.

---

### 9. `test/platform/monty_stack_frame_test.dart` (257 lines)

**Hollowness:** None. Standard value-type test battery.

**Quality:** Good. Tests full and minimal JSON, toJson omits defaults, round-trip, equality for filename/startLine/hideCaret, listFromJson, malformed JSON for each required field. Missing: equality tests for endLine, endColumn, frameName, previewLine, hideFrameName.

**Consolidation:** Self-contained.

---

### 10. `test/platform/monty_state_mixin_test.dart` (163 lines)

**Hollowness:** None. Tests protected mixin behavior via a test harness class. Every assertion tests actual state machine behavior.

**Quality:** Excellent. Tests: initial state, all guard assertions (pass and fail cases), state transitions, full lifecycle, error messages include backendName. Could add: test that `markActive()` when already active is handled, test that `markIdle()` when already idle is handled, test that `markDisposed()` when already disposed is handled (idempotency).

**Consolidation:** Self-contained.

---

### 11. `test/platform/monty_value_scalars_test.dart` (301 lines)

**Hollowness:** Mild. Several tests assert only `toString(), isNotEmpty` -- e.g. "toString is non-empty" for MontyNull, MontyBool, MontyInt, MontyFloat, MontyString. These verify toString doesn't return empty string but don't verify the **actual format**. This pattern appears in every MontyValue subtype across multiple files.

**Quality:** Good overall. Tests NaN/Infinity serialization, negative int, zero, empty string. The `isNotEmpty` toString tests are a quality gap -- they should assert the actual string format (e.g., `'MontyInt(42)'`).

**Consolidation:** Part of the MontyValue test suite split across 7 files (#11-#17). See consolidation section below.

---

### 12. `test/platform/monty_value_collections_test.dart` (419 lines)

**Hollowness:** Same `toString(), isNotEmpty` pattern as #11 for MontyBytes, MontyList, MontyTuple, MontyDict, MontySet, MontyFrozenSet. Same mild hollowness.

**Quality:** Good. Tests empty collections, nested structures, mixed types, full 0-255 byte range. Missing: test for very large collections. Missing: MontySet with duplicate items.

**Consolidation:** Part of the 7-file MontyValue suite. See consolidation section.

---

### 13. `test/platform/monty_value_datetime_test.dart` (436 lines)

**Hollowness:** Same `toString(), isNotEmpty` pattern for MontyDate, MontyDateTime, MontyTimeDelta, MontyTimeZone.

**Quality:** Good. Tests boundary dates (year 1, year 9999, leap day), naive vs aware datetime, negative offsets, microsecond preservation, negative timedelta days, UTC timezone. Missing: midnight boundary (23:59:59 -> 00:00:00), max microseconds.

**Consolidation:** Part of the 7-file MontyValue suite.

---

### 14. `test/platform/monty_value_dispatch_test.dart` (62 lines)

**Hollowness:** None. Tests dispatch edge cases: unknown `__type` fallback, non-JSON input error, recursive nesting.

**Quality:** Good but thin. Only 3 test groups. The nesting tests verify round-trip but don't test deeply nested structures (e.g., 10 levels deep).

**Consolidation:** Could be absorbed into one of the other MontyValue files.

---

### 15. `test/platform/monty_value_from_dart_test.dart` (180 lines)

**Hollowness:** None. Every test verifies specific conversion behavior.

**Quality:** Good. Tests all primitive types, DateTime, List, Map, MontyValue passthrough, unsupported types, non-string map keys, nested structures. Tests special float strings (NaN, Infinity, -Infinity). Also tests `_parseMap` edge cases and `fromJson` special float strings -- these overlap with scalars_test.

**Consolidation:** The "MontyValue.fromJson special float strings" and "_parseMap edge cases" groups (lines 131-179) duplicate tests already in `monty_value_scalars_test.dart` and `monty_value_dispatch_test.dart`. **Remove duplicates.**

---

### 16. `test/platform/monty_value_structured_test.dart` (304 lines)

**Hollowness:** Same `toString(), isNotEmpty` pattern for MontyPath, MontyNamedTuple, MontyDataclass.

**Quality:** Good. Tests MontyPath edge cases (empty, unicode, spaces), MontyNamedTuple empty fields, MontyDataclass nested attrs, frozen flag. Missing: MontyNamedTuple with mismatched field_names/values length.

**Consolidation:** Part of the 7-file MontyValue suite.

---

### 17. `test/platform/monty_value_coverage_test.dart` (182 lines)

**Hollowness:** **Moderate.** This file is explicitly labeled as a coverage booster. The "all types have non-empty toString" group (lines 147-181) iterates every MontyValue type and asserts `isNotEmpty` -- this is hollow since it doesn't verify actual output. The "all typed wrappers survive json encode/decode" group (lines 104-145) asserts only `runtimeType` equality, not value equality.

**Quality:** The `dartValue` coverage group (lines 9-101) is partially redundant with the individual type test files. However, some `dartValue` tests here are the **only** place certain types' dartValue is tested (e.g., MontyTimeZone, MontyNamedTuple, MontyDataclass), so they should be moved to the individual files rather than deleted.

**Consolidation:** **Merge into individual type files.** Move dartValue tests to their respective files. The generic "all types survive json encode/decode" loop should be kept as a single integration-style test but moved into a single MontyValue test file.

---

### 18. `test/platform/base_monty_platform_test.dart` (714 lines)

**Hollowness:** None. This is a substantial, high-quality integration test file using `_FakeCoreBindings`. Every test drives real behavior.

**Quality:** Excellent. Tests: run success/error, start complete/pending/resolve_futures/error, resume, resumeWithError, dispose (including double-dispose, force-idle), state guards (all invalid transitions), limits encoding (null/partial/full, default merging), external functions encoding, lazy initialization, unknown progress state, TOCTOU race safety (#101), state recovery on bindings exception (#74). References real issue numbers.

**Consolidation:** Self-contained. The `_FakeCoreBindings` class is duplicated in `error_hierarchy_test.dart` (file #19). **Extract shared fake to a helper file.**

---

### 19. `test/platform/error_hierarchy_test.dart` (463 lines)

**Hollowness:** None. Detailed error hierarchy tests.

**Quality:** Excellent. Tests sealed hierarchy structure, catch clause ordering, BaseMontyPlatform excType-to-sealed-type mapping (including MemoryLimitExceeded -> MontyResourceError), MontyResult.error vs thrown errors, field extraction with traceback. This file adds significant value beyond `monty_error_test.dart`.

**Consolidation:** **Overlaps with `monty_error_test.dart` (#1).** Both test: sealed hierarchy construction, pattern matching, implements Exception, catch-as-MontyError. The error_hierarchy_test adds: catch ordering, BaseMontyPlatform mapping, MontyScriptError field extraction. **Recommendation: merge #1 into #19 and delete #1.** Also, `_FakeCoreBindings` here duplicates the one in `base_monty_platform_test.dart` (#18).

---

### 20. `test/platform/mock_monty_platform_test.dart` (295 lines)

**Hollowness:** Low. The first three tests ("is a MontyPlatform", "implements MontySnapshotCapable", "implements MontyFutureCapable") are pure type checks. These are borderline -- they verify the mock implements the right interfaces but add no behavioral value.

**Quality:** Good. Tests: run with result recording, snapshot/restore, start/resume/resumeWithError with progress queue FIFO, resumeAsFuture counting, resolveFutures recording, empty queue errors, dispose, convenience getter null defaults. Thorough for a mock test.

**Consolidation:** Self-contained. Tests the testing infrastructure itself -- appropriate as a standalone file.

---

### 21. `test/platform/testing/ladder_assertions_test.dart` (169 lines)

**Hollowness:** None. Tests the assertion helper functions used by ladder test runners.

**Quality:** Good. Tests assertLadderResult (exact, list, null, contains, sorted), assertPendingFields (fnName, args, kwargs null/non-null, callIdNonZero, methodCall), assertExceptionFields (excType, traceback min frames, traceback filename, error filename). Tests that missing keys are no-ops. Missing: tests for assertion **failures** (verifying that assertLadderResult throws when expected != actual).

**Consolidation:** Self-contained. Appropriate in `testing/` subdirectory.

---

### 22. `test/platform/testing/ladder_runner_test.dart` (190 lines)

**Hollowness:** None. Exercises the ladder test runner infrastructure with real mock interactions.

**Quality:** Good. Tests loadLadderFixtures (sorts tiers, ignores non-JSON), runSimpleFixture, runErrorFixture (including failure when no exception thrown), runIterativeFixture (resumeValues and resumeErrors paths). Missing: test for malformed fixture JSON, test for fixture missing required fields.

**Consolidation:** Self-contained. The `_ThrowingMock` helper is file-local and appropriate.

---

### 23. `test/ffi/ffi_core_bindings_test.dart` (607 lines)

**Hollowness:** None. Tests the FFI core bindings layer with MockNativeBindings.

**Quality:** Excellent. Tests: run success/error/printOutput/embedded-error/limits/scriptName/handle-free-on-error/null-resultJson, start complete/pending-all-fields/error/resolve_futures/unknown-tag/external-functions-join, resume/resumeWithError/resumeAsFuture/resolveFutures state-guard and delegation, snapshot/restoreSnapshot with prior handle freeing, dispose lifecycle, handle create/free counting. Very thorough.

**Consolidation:** Self-contained. Uses shared `mock_native_bindings.dart` helper.

---

### 24. `test/ffi/monty_ffi_test.dart` (1015 lines)

**Hollowness:** None. The largest test file in the batch. Comprehensive integration tests for MontyFfi.

**Quality:** Excellent. Tests: run (OK/error/limits/scriptName/disposed/active/handle-free-on-error), start (complete/pending/kwargs/callId/methodCall/printOutput/error/disposed/active/limits/empty-externalFunctions), resume (complete/pending/error/idle/disposed/complex-values/printOutput), resumeWithError (complete/idle/disposed), snapshot/restore (active-state/failure/disposed/active), dispose (double-safe), edge cases (null value, null resultJson, unknown tag, default error message, run error with traceback parsing), resumeAsFuture, resolveFutures with errors, MontyFfi.withCore, handle leak safety (#101).

**Consolidation:** Self-contained. Some behavioral overlap with `base_monty_platform_test.dart` (#18) since MontyFfi delegates to BaseMontyPlatform, but the overlap is at a different layer (FFI vs. abstract platform) so both are warranted.

---

### 25. `test/ffi/monty_native_test.dart` (707 lines)

**Hollowness:** None. Comprehensive tests for the MontyNative isolate-backed platform.

**Quality:** Excellent. Tests: initialize (idempotent, failure), run (result/auto-init/limits/disposed/active/null-value/string-value), start (complete/pending/multiple-ext-fns/null-ext-fns/disposed/active/limits), resume (complete/pending/idle/disposed/complex-values), resumeWithError (complete/continuation/idle/disposed), resumeAsFuture, resolveFutures with errors, snapshot/restore (active-state/failure/disposed/active), dispose (initialized/not-initialized/double-safe), TOCTOU safety (concurrent run, error recovery, bindings throw).

**Consolidation:** Self-contained. Parallels `monty_ffi_test.dart` at the isolate layer -- both are needed.

---

## Summary

| Metric | Count |
|--------|-------|
| Files audited | 25 |
| Total test lines | ~7,800 |
| Hollow tests found | ~25 (`toString isNotEmpty` across value types, trivial type checks) |
| Consolidation opportunities | 4 (see below) |
| Quality gaps | 6 (see below) |
| Files rated Excellent | 10 (#2, #5, #8, #10, #18, #19, #22, #23, #24, #25) |
| Files rated Good | 12 |
| Files with issues | 3 (#1, #15, #17) |

---

## Consolidation Opportunities

### C-1: Merge `monty_error_test.dart` into `error_hierarchy_test.dart`
**Priority: Medium.** File #1 is a strict subset of #19. The hierarchy construction and pattern-matching tests in #1 are duplicated in #19 with more depth. Delete #1 after confirming no unique test cases remain.

### C-2: Extract shared `_FakeCoreBindings` from files #18 and #19
**Priority: Low.** Both `base_monty_platform_test.dart` and `error_hierarchy_test.dart` define nearly identical `_FakeCoreBindings` classes. Extract to a shared `test/platform/testing/fake_core_bindings.dart`.

### C-3: Consolidate MontyValue test files (#11-#17) or at minimum merge #17 and #14
**Priority: Low.** The 7-file split by type category (scalars, collections, datetime, dispatch, fromDart, structured, coverage) is reasonable for navigation, but file #17 (coverage booster) should be dissolved: move dartValue tests into individual type files; keep the json.encode/decode loop as a single test in one file. File #14 (dispatch, 62 lines) is too thin to justify its own file -- merge into #15 (fromDart) which already tests parse-map and dispatch fallback.

### C-4: Remove duplicate tests in `monty_value_from_dart_test.dart`
**Priority: Low.** Lines 131-179 of file #15 duplicate tests from #11 (NaN/Infinity/special float strings) and #14 (unknown `__type` fallback). Remove these groups.

---

## Quality Gaps

### Q-1: `toString isNotEmpty` tests are hollow
**Priority: Medium.** ~18 tests across files #11-#13, #16-#17 assert only `isNotEmpty` on toString output. Replace with exact string assertions (e.g., `expect(const MontyInt(42).toString(), 'MontyInt(42)')`). This catches regressions in display format.

### Q-2: MontyPlatform API surface may be stale (#4)
**Priority: Medium.** `monty_platform_test.dart` only tests `run`, `start`, `resume`, `resumeWithError`, `dispose`. If `MontyPlatform` now also defines `resumeAsFuture`, `resolveFutures`, `snapshot`, `restoreSnapshot`, these need coverage.

### Q-3: Missing boundary/negative-value tests for MontyLimits (#3)
**Priority: Low.** No tests for negative memoryBytes, negative timeoutMs, zero stackDepth. If the API accepts these, boundary behavior should be documented via test. If it rejects them, validation tests are needed.

### Q-4: MontyStackFrame equality incomplete (#9)
**Priority: Low.** Equality tests cover filename, startLine, hideCaret but skip endLine, endColumn, frameName, previewLine, hideFrameName. Add inequality tests for the missing fields.

### Q-5: Ladder assertion failure paths not tested (#21)
**Priority: Low.** `ladder_assertions_test.dart` tests that assertions pass on correct input but never verifies they fail on incorrect input (e.g., `assertLadderResult(MontyInt(42), {'id': 1, 'expected': 99})` should throw).

### Q-6: Coverage booster tests mask actual gaps (#17)
**Priority: Medium.** `monty_value_coverage_test.dart` was written to inflate line coverage metrics. The json.encode loop asserts only `runtimeType` match (not value equality), and the toString loop asserts only `isNotEmpty`. These tests pass even if serialization is broken. Fix by asserting value equality in the round-trip loop and exact strings in the toString loop.

---

## Prioritized Action Items

1. **Q-1 + Q-6: Fix hollow toString and coverage-booster tests** -- Replace `isNotEmpty` with exact string assertions; replace `runtimeType` check with value equality in round-trip loop. Prevents false confidence from coverage metrics.

2. **C-1: Merge `monty_error_test.dart` into `error_hierarchy_test.dart`** -- Eliminates 146 lines of duplicate tests. Quick win.

3. **Q-2: Verify MontyPlatform test covers current API surface** -- Check if methods were added since the test was written. Add missing method stubs.

4. **C-4: Remove duplicate special-float and dispatch tests from `monty_value_from_dart_test.dart`** -- Lines 131-179 are copy-paste from other files.

5. **C-2: Extract shared `_FakeCoreBindings`** -- Reduces maintenance burden when the bindings interface changes.

6. **Q-3, Q-4, Q-5: Add missing edge-case tests** -- Low priority but improves robustness. Can be done incrementally.

7. **C-3: Dissolve `monty_value_coverage_test.dart`** -- Move useful tests to proper homes; delete the file.
