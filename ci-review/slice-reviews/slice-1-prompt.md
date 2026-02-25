# Slice 1 Review

You are a strict, adversarial Principal Engineer reviewing refactoring
Slice 1 for the dart_monty project. Do not trust the author's
stated intentions — verify every claim against the unified diff.

The unified diff is provided as `slice-1.diff`. The changed
source files are provided alongside this prompt. Read the diff first,
then cross-reference with the source files.

**Branch:** refactor/slice-1-test-pruning | **SHA:** b046774 | **Date:** 2026-02-25T15:32:27Z

---

## Review Instructions

**Review process — for each question below, you MUST provide:**

1. **Analysis** (3-5 sentences): Deep technical analysis. Quote specific
   lines from the unified diff as evidence. Do NOT use metrics tables as
   proof of behavioral correctness — metrics measure quantity, not behavior.
2. **Verdict**: PASS or FAIL.

**Review questions:**

1. **Behavioral parity:** Read the unified diff. Did any production code
   in `lib/` or `src/` change? For deleted tests, read the exact lines
   removed — were they truly tautological (testing language semantics, not
   business logic) or did they cover real FFI/serialization boundaries?
2. **API surface:** Check the diff for changes to files in `lib/`. Were
   any public classes, methods, or parameters added, removed, or renamed?
   Is it intentional per the slice spec?
3. **Test quality:** Look at remaining tests in the diff. Are assertions
   meaningful? Do they test production behavior or just mirror the
   implementation? Any new tests that are tautological?
4. **Design doc accuracy:** Does the architecture.md diff (if any)
   accurately describe the design intent? Is anything misleading or
   missing? If the slice spec says "no design change," confirm no
   architecture.md changes exist in the diff.
5. **Cross-platform impact:** Do the diff changes touch platform-specific
   APIs (`dart:ffi`, `dart:js_interop`, podspec, CMakeLists) in a way
   that affects iOS/Android/Windows expansion readiness?

**Scope guardrails — the reviewer MUST NOT:**

- Suggest adding tests beyond what the slice spec requires. The goal is
  fewer tests with higher signal, not more tests. If coverage dropped,
  check whether the deleted tests were tautological per the spec.
- Suggest defensive coding (extra null checks, redundant type guards,
  assertion methods). Trust the type system and the contracts.
- Suggest refactoring code outside the slice's stated scope. If it's not
  in the slice spec, it's not in this PR.
- Suggest adding error handling for scenarios that cannot happen given
  the state machine contracts.
- Suggest abstracting, extracting, or generalizing code that the slice
  doesn't touch. No "while you're here, you could also..." feedback.
- Expand dartdoc or comments beyond what the slice requires. Dartdoc
  completeness is a release prep task, not a per-slice requirement
  (except for files the slice modifies).

**The reviewer SHOULD:**

- Flag behavioral regressions (test failures, parity breaks) — FAIL.
- Flag unintended public API changes — FAIL.
- Flag design doc inaccuracies — FAIL.
- Flag deviations from the slice spec — note, not FAIL (author may have
  good reasons).
- Confirm the net line delta is in the expected range.
- Confirm metrics match the "After" column in the PR description.

---

## Slice Spec

## Slice 1: Test Pruning + Trivial Cleanup

**Goal:** Remove tests that provide zero defect-finding value. Minimal source
changes (dead code only).

### Changes

| Delete/Change | Est. Lines | Rationale |
|---------------|----------:|-----------|
| Tautological constructor/identity tests (5 data model test files) | ~230 | Tests that Dart assigns named params to fields |
| `mock_monty_platform_test.dart` (keep only `PlatformInterface.verify` test) | ~450 | Tests a test double, not production code |
| `integration.rs` behavioral duplicates (keep boundary/safety tests) | ~700 | 40% of file re-tests `handle.rs` unit coverage |
| Remove unused `mocktail` dev dependencies | ~6 | 3 packages declare but never import |
| Consolidate `DeepCollectionEquality` private const | ~4 | Identical declaration in `monty_exception.dart` and `monty_stack_frame.dart` |
| Extract `_defaultCompleteJson` const | ~4 | Identified in synthesis as zero-risk cleanup |

**Net removal:** ~1,394 lines
**Risk:** MEDIUM. Dart test deletion is low-risk (pure deletion, no source
changes). **Rust integration test pruning is MEDIUM risk** — integration tests
may catch cross-boundary serialization issues that unit tests mock away.
Before deleting Rust tests, verify that `handle.rs` unit tests cover the
same FFI boundary conditions (null pointers, malformed UTF-8, JSON parse
errors).
**Note:** Absolute per-package coverage will drop because tautological tests
are being removed. This is expected and intentional — the patch coverage gate
does not penalize pure deletion.
**Gate:** All remaining tests pass. Patch coverage check (no new lines).
**Design doc:** None — no design change.
**Ship:** Point release. Identical behavior, fewer tests.

---

## Diff Stats

```
 PLAN.md                                            |   5 +
 docs/refactoring-plan.md                           |  61 +-
 native/tests/integration.rs                        | 836 ++++++---------------
 packages/dart_monty_desktop/pubspec.yaml           |   1 -
 .../dart_monty_ffi/test/mock_native_bindings.dart  |  16 +-
 .../dart_monty_platform_interface/pubspec.yaml     |   1 -
 .../test/mock_monty_platform_test.dart             | 459 -----------
 .../test/monty_exception_test.dart                 |  56 --
 .../test/monty_progress_test.dart                  |  78 --
 .../test/monty_resource_usage_test.dart            |  33 -
 .../test/monty_result_test.dart                    |  56 --
 .../test/monty_stack_frame_test.dart               |  40 -
 packages/dart_monty_web/pubspec.yaml               |   1 -
 pubspec.yaml                                       |   1 -
 tool/test_platform_interface.sh                    |   4 +
 tool/test_rust.sh                                  |   6 +-
 16 files changed, 292 insertions(+), 1362 deletions(-)
```

## Metrics Delta (Before → After)

| Package | Metric | Before | After | Delta |
|---------|--------|-------:|------:|------:|
| dart_monty_platform_interface | source lines | 1242 | 1242 | 0 |
| dart_monty_platform_interface | test lines | 2918 | 2196 | -722 |
| dart_monty_platform_interface | test count | 282 | 201 | -81 |
| dart_monty_platform_interface | coverage pct | 100 | 100 | 0 |
| dart_monty_ffi | source lines | 1441 | 1441 | 0 |
| dart_monty_ffi | test lines | 2147 | 2147 | 0 |
| dart_monty_ffi | test count | 93 | 93 | 0 |
| dart_monty_ffi | coverage pct | 45 | 45 | 0 |
| dart_monty_wasm | source lines | 710 | 710 | 0 |
| dart_monty_wasm | test lines | 1759 | 1759 | 0 |
| dart_monty_wasm | test count | 80 | 80 | 0 |
| dart_monty_wasm | coverage pct | 100 | 100 | 0 |
| dart_monty_web | source lines | 110 | 110 | 0 |
| dart_monty_web | test lines | 846 | 846 | 0 |
| dart_monty_web | test count | 52 | 52 | 0 |
| dart_monty_web | coverage pct | N/A | N/A | — |
| dart_monty_desktop | source lines | 752 | 752 | 0 |
| dart_monty_desktop | test lines | 1363 | 1363 | 0 |
| dart_monty_desktop | test count | 72 | 72 | 0 |
| dart_monty_desktop | coverage pct | 100 | 100 | 0 |
| **Dart totals** | dart source lines | 4255 | 4255 | 0 |
| **Dart totals** | dart test lines | 9033 | 8311 | -722 |
| **Dart totals** | dart test count | 579 | 498 | -81 |
| **Dart totals** | test to source ratio | 2.1 | 1.9 | — |
| **Rust** | source lines | 2728 | 2728 | 0 |
| **Rust** | test lines | 1717 | 1333 | -384 |
| **Rust** | test count | 145 | 135 | -10 |
| **Rust** | clippy | pass | pass | — |

## Gate: SKIPPED

(gate skipped via --skip-gate)

---

*Generated by tool/slice_review.sh*
