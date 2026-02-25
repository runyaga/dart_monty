# Refactoring Plan: dart_monty Architecture Cleanup

**Date:** 2026-02-25 (v3)
**Input:** `ci-review/arch-review/00-summary.md` (3-engine architecture review synthesis)

**Reviews:**

- `ci-review/arch-review/gemini-plan-critique.md` (Gemini critique of v1)
- `ci-review/arch-review/codex-plan-critique.md` (Codex critique of v2, with Gemini cross-review)

**Scope:** All 6 Dart packages + 1 Rust crate

---

## Philosophy

Each slice is a **branch → PR → point release** cycle. No slice depends on a
future slice being completed. Every slice leaves the codebase strictly better
than before, and every intermediate state is a valid release.

Slices are ordered so that earlier ones unlock efficiency in later ones, but
any slice can be dropped or deferred without breaking the sequence.

---

## Slice 0: Quality Gate Baseline

**Goal:** Lock down metrics and automate the gate before any code changes.

### Deliverables

1. **`tool/gate.sh`** — single script that runs every quality check:
   - `dart format --set-exit-if-changed .`
   - `dart analyze --fatal-infos` (per sub-package)
   - `dart doc --validate-links` (per sub-package)
   - `python3 tool/analyze_packages.py`
   - `pymarkdown scan **/*.md`
   - `gitleaks detect`
   - `bash tool/test_platform_interface.sh`
   - `bash tool/test_rust.sh`
   - `bash tool/test_ffi.sh`
   - `bash tool/test_python_ladder.sh`

2. **`tool/metrics.sh`** — captures a machine-readable snapshot:
   - Test count per Dart package
   - Source vs test line counts per package
   - Coverage percentage per package
   - Rust test count and clippy status

3. **`ci-review/baseline.json`** — initial metrics snapshot

4. **`docs/architecture.md`** — skeleton with section headings:
   - State Machine Contract (filled by Slice 4)
   - Cross-Language Memory Contracts (filled by Slice 7)
   - Error Surface and Recovery Semantics (filled by Slice 7)
   - Cross-Backend Parity Guarantees (filled by Slice 5)
   - Execution Paths — Web (filled by Slice 6)
   - Execution Paths — Native (filled by Slice 7)
   - Testing Strategy (filled by Slice 5)
   - Testing Utilities (filled by Slice 3)
   - Native Crate Architecture (filled by Slice 8)

### Gate Rule (applies to every subsequent slice)

Every slice PR must show:
- `tool/gate.sh` passes (zero warnings, zero test failures)
- **Patch coverage:** new/modified lines must meet project threshold (90%).
  Absolute per-package coverage is tracked but not gated — allows safe
  deletion of low-value tests without requiring replacement tests. Use
  `// coverage:ignore` sparingly for hand-rolled boilerplate.
- `git diff --stat` in PR description shows net line delta
- `tool/metrics.sh` before/after comparison

### Design Doc Rule (applies to every subsequent slice)

Each slice writes or updates a section in `docs/architecture.md` describing
the **design intent** — why the abstraction exists, what it guarantees, what
the contracts are. Not implementation details — no line counts, no file names
in the architecture doc.

---

## Slice Review Process

Every slice follows this checklist. No slice merges until every step passes.

### Step 1: Pre-PR (author, before opening PR)

- [ ] `tool/gate.sh` passes locally (zero warnings, zero test failures)
- [ ] `tool/metrics.sh` captured before and after — diff saved for PR body
- [ ] No new public API surfaces test infrastructure (mocks, test helpers)
- [ ] If Rust touched: `cargo test && cargo clippy -- -D warnings && cargo fmt --check`
- [ ] Patch coverage: new/modified lines meet 90% threshold
- [ ] Architecture doc updated if slice spec says so

Note: `dart doc --validate-links`, `dart analyze --fatal-infos`, `dart format`,
`pymarkdown scan`, and `gitleaks detect` are all included in `tool/gate.sh` —
no separate manual checks needed.

### Step 2: PR Description (required sections)

```markdown
## What changed
<1-3 sentences: what this slice does and why>

## Metrics delta
| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Source lines | | | |
| Test lines | | | |
| Coverage (pkg) | | | |
| Test count | | | |

## Gate output
<paste `tool/gate.sh` summary or link to CI run>

## Design doc
<link to architecture.md diff, or "N/A — no design change">

## Risks / decisions made
<any choices made during implementation that deviate from the slice spec>
```

### Step 3: AI Review (before merge)

Each slice PR gets a structured review from Gemini. Run `tool/slice_review.sh`
to assemble a self-contained prompt with metrics, gate output, changed file
contents, and the review rubric:

```bash
bash tool/slice_review.sh N                # full: tests + gate + metrics + assemble
bash tool/slice_review.sh N --skip-tests   # reuse existing lcov data
bash tool/slice_review.sh N --skip-gate    # skip gate.sh
bash tool/slice_review.sh N --skip-all     # skip both, assemble from existing data
```

Output:

- `ci-review/slice-reviews/slice-N-prompt.md` — review instructions + metrics
- `ci-review/slice-reviews/slice-N.diff` — unified diff (what actually changed)

Pass the prompt, the diff, and the changed source files to
`mcp__gemini__read_files` with model `gemini-3.1-pro-preview`. Save the
response to `ci-review/slice-reviews/slice-N-review.md`.

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

Review output goes to `ci-review/slice-reviews/slice-N-review.md`.

### Step 4: Post-Merge Verification

- [ ] `tool/gate.sh` passes on `main` after merge
- [ ] `tool/metrics.sh` on `main` matches PR's "After" column
- [ ] Tag the release (`vX.Y.Z` per affected packages)
- [ ] Changelog updated per affected packages
- [ ] If slice has a "Design doc" deliverable, verify the section exists in
      `docs/architecture.md` on `main`

### Step 5: Baseline Update

- [ ] Run `tool/metrics.sh > ci-review/baseline.json` to update baseline
- [ ] Commit updated baseline to `main`
- [ ] This becomes the starting point for the next slice's "Before" column

---

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

## Slice 2: Fix `restore()` State Divergence

**Goal:** Fix a likely bug where Desktop's `restore()` does not set state to
active like WASM does. **Separated from Slice 4** so the behavior change is
isolated from the structural refactoring — if a test fails, it's unambiguously
the bug fix or the refactor, not both.

### Changes

| Change | Detail |
|--------|--------|
| Fix: `MontyDesktop.restore()` state handling | Should match WASM behavior (set state to active) |
| Add: Regression test for `restore()` state | Verify all backends agree on post-restore state |

**Net removal:** 0 (small addition)
**Risk:** Low — behavior change but clearly scoped.
**Gate:** `tool/gate.sh` passes. New regression test passes.
**Design doc:** None (state machine docs come in Slice 4).
**Ship:** Point release. Changelog notes `restore()` bug fix.
**Depends on:** Nothing. Can merge before or after Slice 1.

---

## Slice 3: Mock & API Surface Cleanup

**Goal:** Clean up the public API surface and mock infrastructure. **Runs
early** because Slice 5 (Shared Test Harness) builds on stable mock
infrastructure — mock cleanup should precede harness construction.

### Prerequisite

**Export audit:** Before starting, verify whether `MockMontyPlatform` is
reachable via the public API of `dart_monty_platform_interface`. Check:
- `dart doc` output for the package
- `lib/dart_monty_platform_interface.dart` barrel exports
- `lib/dart_monty_testing.dart` barrel (does this file already exist, or does
  it need to be introduced?)

If `MockMontyPlatform` is publicly exported, the move is a breaking change
even under `0.x.x` semver. Document the migration path in the changelog.

### Changes

| Change | Detail |
|--------|--------|
| Move `MockMontyPlatform` from `lib/src/` to `dart_monty_testing.dart` barrel or `test/` | Stops shipping mock as production artifact |
| Introduce or update `dart_monty_testing.dart` barrel | Create if it doesn't exist; clarify what it exports |
| Add `@visibleForTesting` to `resetInstance()` | Prevents accidental production use |
| Delete `MontyStackFrameListEquality` extension + tests | Dead code (no production consumers) |
| Evaluate mocktail adoption vs hand-rolled | Decision checkpoint — either consolidate patterns or migrate |

**Net removal:** ~80 lines + cleaner API surface
**Risk:** Low-Medium — export audit (above) determines actual breakage scope.
**Gate:** `tool/gate.sh` passes. `dart doc` output no longer shows mock in
public API.
**Design doc:** Add "Testing Utilities" section describing what
`dart_monty_testing.dart` exports and the mock strategy decision.
**Ship:** Point release. Semver note on `MockMontyPlatform` relocation.
**Depends on:** Nothing.

---

## Slice 4: State Machine Consolidation

**Goal:** Extract the triplicated `_State` lifecycle into a single shared
mixin in `platform_interface`. **Pure structural refactoring** — no behavior
changes (the `restore()` bug is already fixed in Slice 2).

### Changes

| Change | Detail |
|--------|--------|
| New: `monty_state_mixin.dart` in `platform_interface/lib/src/` | `_State` enum, guard methods, `rejectInputs`, `dispose()` idempotency |
| Modify: `MontyFfi`, `MontyWasm`, `MontyDesktop` | `with MontyStateMixin` — delete local copies |
| New: State machine unit tests in `platform_interface/test/` | One canonical set (currently triplicated) |
| Delete: Per-backend state machine test groups | ~265 lines across 3 test files |

**Net removal:** ~385 lines (add ~40 mixin + tests, delete ~120 source + ~265 tests)
**Risk:** Medium — touches 3 packages, must maintain behavioral parity.
**Gate:** `tool/gate.sh` passes. All 3 backends use mixin.
**Design doc:** Fill "State Machine Contract" section. Document the lifecycle
(`idle → active ↔ pending → idle | disposed`), the invariants each guard
enforces, and the `initialize()` contract.
**Ship:** Point release for `platform_interface`, `ffi`, `wasm`, `desktop`.
**Depends on:** Slice 2 (bug fix already landed).

---

## Slice 5: Shared Test Harness

**Goal:** Extract a contract test suite that all backends invoke, eliminating
structural test duplication.

### Changes

| Change | Detail |
|--------|--------|
| New: `platform_interface/test/shared/` | `monty_platform_contract.dart` — parameterized by mock factory |
| New: Shared smoke test helpers | `shouldPassSmokeTests(factory)` |
| New: Shared ladder assertion utilities | `assertResult`, `assertPendingFields`, `assertExceptionFields` |
| New: Shared fixture loading helper | Extract identical 6-line `Directory.listSync` pattern from FFI/Desktop/runners |
| Modify: Backend test files | Replace duplicated groups with shared suite calls |
| Fix: Desktop ladder fidelity gap | Add `xfail` handling and `async/futures` execution path |

**Net removal:** ~505 lines
**Risk:** Medium — changes test structure across all packages.
**Gate:** `tool/gate.sh` passes. Each backend test file is shorter but
invokes shared suite. Desktop ladder now validates `excType`, `traceback`,
`kwargs`.
**Design doc:** Fill "Testing Strategy" and "Cross-Backend Parity Guarantees"
sections. Describe the contract test pattern: each backend validates
`MontyPlatform` behavioral contract via shared helpers, plus backend-specific
tests for transport concerns. Document what "parity" means and how it's
verified.
**Ship:** Point release. More tests pass on Desktop (fidelity improvement).
**Depends on:** Slice 3 (mock infrastructure stable), Slice 4 (mixin makes
contract test cleaner).

---

## Slice 6: Web Package Simplification

**Goal:** Eliminate the `DartMontyWeb` pass-through wrapper. `MontyWasm`
registers directly via Flutter's federated plugin convention.

### Changes

| Change | Est. Lines | Detail |
|--------|----------:|--------|
| Reduce `DartMontyWeb` to registration-only shim | ~100 removed | `registerWith()` does `MontyPlatform.instance = MontyWasm(...)` — nothing else |
| Delete `dart_monty_web_test.dart` | ~643 | 100% delegation tests with zero incremental value |
| Delete `dart_monty_web/test/mock_wasm_bindings.dart` | ~203 | Byte-for-byte duplicate of WASM package copy |
| Remove triplicated `UnsupportedError` guards | ~20 | Web was shadowing WASM's identical throws |
| New: Flutter web integration test | — | Full end-to-end test in headless Chrome verifying `registerWith()` wiring, not just the spike |

**Net removal:** ~966 lines
**Risk:** **HIGH** — Flutter web plugin registration (`registerWith()`) is
notoriously finicky. If `MontyWasm` does not perfectly match the expected web
platform interface signature, it will compile but fail at runtime. The
existing spike is insufficient validation — this slice requires a formal
Flutter web integration test that exercises the full `registerWith()` →
`MontyPlatform.instance` → `run()` → result path in headless Chrome.
**Gate:** `tool/gate.sh` passes. Flutter web integration test passes. Ladder
parity preserved in headless Chrome.
**Design doc:** Fill "Execution Paths — Web" section. Describe why
`dart_monty_web` exists (Flutter convention) and what it does NOT do (no logic,
no guards, no type mapping).
**Ship:** `dart_monty_web` point release.

---

## Slice 7: Desktop & WASM Refinement

**Goal:** Smaller targeted cleanups in the two heavier backends. Also
prepares `dart_monty_ffi` for iOS platform expansion (M9).

### Changes

| Change | Detail |
|--------|--------|
| Remove `DesktopRunResult`/`DesktopProgressResult` wrappers | Return domain types directly from `DesktopBindings` |
| Extract worker progress dispatch helper in `worker_src.js` | `postProgress(progress, id)` replaces 3x copy-paste |
| Add `_failAllPending` test coverage in Desktop | Currently zero tests for isolate error recovery path |
| Measure `timeElapsedMs` with `Stopwatch` in WASM | Replace synthetic zeros with actual elapsed time |
| Evaluate `resolveFutures`/`resolveFuturesWithErrors` merge | Single method with optional errors map (touches platform_interface) |
| Prepare iOS library loading in `NativeBindingsFfi` | Add `DynamicLibrary.process()` path for `Platform.isIOS` (static linking) |

**WASM timer caveat:** Browser Spectre mitigations clamp/fuzz high-resolution
timers. `Stopwatch` in WASM may return imprecise values. All `timeElapsedMs`
assertions must use tolerance-based comparisons (e.g., `greaterThan(0)`,
not exact values) to avoid flaky CI under the zero-failure gate rule.

**Net removal:** ~180 lines + new test coverage for previously-untested paths
**Risk:** Low-Medium.
**Gate:** `tool/gate.sh` passes. New Desktop isolate error test passes.
**Design doc:** Fill "Execution Paths — Native", "Cross-Language Memory
Contracts", and "Error Surface and Recovery Semantics" sections. Document
the FFI/WASM memory lifecycle (who allocates, who frees, exception/panic
behavior) and isolate failure recovery paths.
**Ship:** Desktop + WASM + FFI point releases.
**Depends on:** Nothing, but benefits from Slice 4 (mixin) being done.

---

## Slice 8: Rust Crate Consolidation

**Goal:** Collapse the Limited/NoLimit generics duplication that inflates
`handle.rs` by ~200 lines. **Pushed to end** because it is completely isolated
from Dart structural changes and carries the highest technical risk.

### Changes

| Change | Detail |
|--------|--------|
| Unify `HandleState` variants | Internal `TrackerSlot` enum or `Box<dyn Any>` to store either tracker type |
| Collapse `process_progress_limited`/`no_limit` | Single generic method or macro |
| Extract FFI boilerplate macro in `lib.rs` | `ffi_wrap!(handle, out_error, closure)` for null-check + panic boundary |
| Extract `PrintWriter` drain helper | Replaces 14 repeated drain patterns |

**Net removal:** ~380 lines from Rust crate
**Risk:** Highest of all slices. Rust generics interaction with `monty`
crate's `ResourceTracker` trait. Prototype on a branch first. **Caution:**
over-using macros to collapse code can result in fewer lines but harder
debugging — prioritize readability over line count.
**Gate:** `cargo test`, `cargo clippy -- -D warnings`, `cargo fmt --check`.
Then `tool/gate.sh` for Dart integration.
**Design doc:** Fill "Native Crate Architecture" section. Describe the handle
lifecycle (create → run/start → resume → free), the FFI boundary contract
(JSON in, JSON out, error via out-parameter), and the tracker abstraction.
**Ship:** Point release. Behavior identical.
**Depends on:** Nothing. Independent of all Dart slices.

---

## Order of Operations

```text
Slice 0   Quality gates + baseline           ← prerequisite for all
  │
  ├─── Slice 1   Test pruning + cleanup      ← lowest risk, biggest bang
  │
  ├─── Slice 2   Fix restore() bug           ← isolated behavior change
  │
  ├─── Slice 3   Mock & API cleanup          ← stabilizes mock infra
  │
  ├─── Slice 8   Rust consolidation          ← independent, highest risk
  │
  └─── Slice 4   State machine mixin         ← unlocks Slice 5
         │
         └─── Slice 5  Shared test harness   ← depends on Slices 3 + 4
                │
                ├─── Slice 6  Web simplification (HIGH risk)
                │
                └─── Slice 7  Desktop & WASM refinement + iOS prep
```

**Recommended order:** `0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8`
**Critical path:** `0 → 1 → 2 → 3 → 4 → 5`
**Parallelizable:** Slices 1, 2, 3, 8 are independent of each other after
Slice 0. Slice 8 can run any time.

---

## Deferred Decisions

These items came up during analysis but do not belong in any slice above.

### Code-gen adoption (freezed / equatable / json_serializable)

All 3 engines agree the data model boilerplate could use code-gen. Deferred
because:
- Adds `build_runner` as a build-time dependency
- Changes the developer workflow
- Current hand-rolled code is correct, just verbose
- Payoff is ~550 lines but introduces new tooling

**Trigger to revisit:** When the next milestone adds a new data model type or
adds more than 2 new fields to existing types, re-evaluate whether code-gen
pays for itself.

If adopted later, make it a dedicated slice with its own PR so the migration
is atomic and reviewable.

### Sync-over-async in MontyFfi

`MontyFfi` wraps synchronous FFI calls in `async`/`Future` without offloading
to an Isolate. `MontyDesktop` already solves this with the Isolate pattern.
Making `MontyFfi` use `Isolate.run()` would be correct but changes observable
behavior (microtask scheduling).

**Why deferred (not a slice):** `MontyFfi` is not used directly in Flutter
apps — `MontyDesktop` wraps it in an Isolate before it reaches the UI thread.
The sync-over-async issue only affects bare `MontyFfi` consumers (tests, CLI
tools) where main-thread jank is not observable. If a future milestone adds a
non-Isolate path that exposes `MontyFfi` to Flutter UI, this must be promoted
to a dedicated slice immediately.

**Note:** `MontyDesktop` cannot be eliminated or collapsed into `MontyFfi`
because `dart_monty_desktop` owns Flutter plugin registration, native library
bundling (podspec, CMakeLists), and the `ffiPlugin: true` declaration. The
FFI package must remain pure Dart with no Flutter dependency. The current
layering (FFI = pure Dart bindings, Desktop = Flutter glue + Isolate) is
architecturally correct.

### The `inputs` parameter

Every backend rejects it with `_rejectInputs`. If it is not needed for M7A or
later milestones, consider removing it from `MontyPlatform`. **This is a
breaking API change** — requires a semver-major bump (or a `0.x` minor bump
with migration notes). This would cascade simplification through all backends
and tests.

### WASM test harness divergence

The print-based test protocol (vs `package:test`) exists because WASM tests
drive a Worker in headless Chrome, which does not fit `package:test` well.
This is an intentional platform constraint, not a bug. Document it rather than
trying to unify it.

### Package rename: `dart_monty_desktop` → `dart_monty_native`

When iOS, Android, and Windows are added (M9), "desktop" becomes misleading.
The Dart code (Isolate, state machine, registration) is identical across all
native platforms — only the build files differ per OS.

**This decision must be made before M9 planning begins** — renaming a pub.dev
package requires publishing a new package name and deprecating the old one,
which takes migration time. While the package is `0.x.x` semver allows the
break, but downstream consumers need notice.

---

## Platform Expansion Readiness (M9 Context)

This refactoring was designed with awareness that iOS, Android, and Windows
support is coming. Key compatibility notes:

### Already ready

- `NativeLibraryLoader` handles iOS/Android/Windows in `_platformDefault()`
- Rust `Cargo.toml` produces `staticlib` (needed for iOS `.a`)
- `DesktopBindingsIsolate` uses `Isolate.spawn` (works on all 5 native platforms)
- `MontyDesktop` has no platform-specific Dart code

### Needs work (addressed in Slice 7 or M9)

- `NativeBindingsFfi` hardcodes `DynamicLibrary.open()` — iOS needs `DynamicLibrary.process()`
- `pubspec.yaml` needs iOS/Android/Windows platform entries
- New build files: iOS podspec, Android build.gradle/CMakeLists, Windows CMakeLists
- Rust cross-compilation CI scripts

See `ci-review/arch-review/gemini-platform-expansion-review.md` for detailed
per-platform analysis.

---

## Release Strategy

**No pub.dev releases until all 9 slices are complete.** Ship as **0.5.0**.

### Rationale

- Zero external consumers today — no cost to batching
- Avoids cluttering pub.dev with 0.4.4..0.4.12 that nobody uses
- Package rename (`desktop` → `native`) lands cleanly in the same version bump
- One changelog entry, one migration story

### How it works

- Each slice merges to `main` individually with full gate checks
- `pubspec.yaml` versions stay at `0.4.x` throughout development
- After Slice 8 completes: bump all packages to `0.5.0` in a release prep commit
- Publish all packages in dependency order per `CONTRIBUTING.md`
- If the package rename happens, publish `dart_monty_native` as a new package
  and mark `dart_monty_desktop` as discontinued on pub.dev

### The "each slice is shippable" guarantee

This still holds — each slice leaves `main` in a valid, working state. The
guarantee means "could ship if needed," not "must ship." If an urgent bug
fix requires a 0.4.x release mid-refactoring, any intermediate state is safe
to tag and publish.

---

## Development Workflow Enhancements

Changes to tooling and process that apply across all slices.

### DCM Enhancements

DCM is already at Stage 2 with aggressive rules. Add these for the refactoring:

**Add to `gate.sh` (Slice 0):**
- `dcm analyze packages` — currently only in pre-commit, not in the gate
- `dcm check-unused-code packages` — catches dead code during deletion slices
- `dcm check-unused-files packages` — catches orphaned files after moves
- `dcm check-dependencies packages` — catches unused deps (validates Slice 1
  mocktail removal, etc.)

**Enforce `public_member_api_docs` across all packages:**
Currently only `platform_interface` has `public_member_api_docs: true`.
Enable it in all package `analysis_options.yaml` files during Slice 0.
This ensures every public API member has dartdoc before 0.5.0 ships.

**New DCM rules to consider:**
- `prefer-extracting-callbacks` — catches inline closures that hurt readability
- `avoid-long-parameter-list` — already covered by `number-of-parameters: 6`
- `avoid-returning-widgets` — not applicable (no Flutter widgets in these packages)

### Pre-Commit Hook Updates

Current hooks are comprehensive. Add during Slice 0:
- `dart doc --validate-links` per package (catches broken doc references)
- `dcm check-unused-code` (catch dead code before it reaches CI)

### Example Files

Current `example/` files are minimal. During documentation pass (see below),
upgrade each package's example to demonstrate the primary use case with
runnable code. pub.dev scores packages higher when `example/` is substantive.

---

## Documentation Strategy

**Goal:** Make dart_monty documentation excellent for both humans reading
pub.dev and AI agents using context7/RAG. Context7 indexes from three sources:
pub.dev dartdoc pages, pub.dev package README, and GitHub repo files. All
three must be rich.

### What context7 indexes well

Based on high-scoring Dart packages (riverpod: 769 snippets, score 88):
- `///` dartdoc comments with inline code examples (`/// ```dart ... ````)
- README.md with structured sections and code blocks
- `example/` files that are complete and runnable
- Consistent naming and clear type hierarchies

### Documentation deliverables (part of 0.5.0 release prep)

**1. Dartdoc coverage — enforced by lint:**
- `public_member_api_docs: true` in all packages (Slice 0)
- Every public class, method, and property gets `///` with:
  - One-line summary
  - Longer description if behavior is non-obvious
  - `/// ```dart` code example for key APIs (run, start, resume, dispose)
  - `/// See also:` cross-references to related types
- **Target:** context7 extracts code snippets from dartdoc `///` comments

**2. README per package — structured for scanning:**
Each package README follows this template:

```markdown
# package_name

One-line description.

## Quick Start
<3-5 line code example that works>

## Key Types
<table: Type | Description>

## Platform Support
<matrix: Platform | Status>

## Usage Patterns
### Basic: Run Python code
### Iterative: External function calls
### Async: Future resolution
<each with a self-contained code block>

## Architecture
<1 paragraph + link to docs/architecture.md>
```

**3. `example/` files — runnable and rich:**
Each package's `example/example.dart` demonstrates the primary flow:
- `platform_interface`: Construct types from JSON, inspect fields
- `ffi`: Create bindings, run code, read result
- `desktop`: Register plugin, run with isolate, handle progress
- `wasm`: Initialize worker, run code, handle async
- `web`: Registration shim (minimal — points to wasm/desktop)

**4. `docs/architecture.md` — the agent reference:**
Already planned in Slice 0. This is the document that gives agents (and
humans) the mental model. Sections from the skeleton plus:
- **Quick orientation** — what this project is, 3-sentence summary
- **Package dependency graph** — ASCII diagram
- **JSON contract reference** — the shapes that cross FFI/WASM boundaries
- **Platform support matrix** — what works where
- Each section uses the `docs/architecture.md#section-name` anchor pattern
  so agents can deep-link

**5. `docs/cookbook.md` — agent-friendly usage patterns:**
A flat file of self-contained recipes, each with:
- Title (searchable)
- 10-20 line code block
- One-line explanation of what it demonstrates

Recipes:
- Run Python and get the result
- Run with resource limits
- Iterative execution with external functions
- Handle Python exceptions
- Snapshot and restore interpreter state
- Async futures resolution
- Use from a Flutter app (desktop)
- Use from a Flutter app (web)

This file is specifically designed for RAG retrieval — each recipe is
independent and self-contained, so a context window gets a complete answer
without needing surrounding context.

### When documentation happens

Documentation is NOT a separate slice — it's woven into the release prep:
- **Slice 0:** Enable `public_member_api_docs: true`, create architecture.md
  skeleton
- **Slices 1-8:** Each slice fills its architecture.md section and fixes any
  dartdoc gaps in files it touches
- **Release prep (post Slice 8):** Demo consolidation, final pass on all
  READMEs, example files, cookbook, and dartdoc. This is the last commit
  before version bump to 0.5.0.

---

## Release Prep (Post Slice 8, Pre 0.5.0)

After all 9 slices are complete, these tasks happen before the version bump.

### Demo Consolidation

**Problem:** The project has 4 separate example/demo setups that duplicate
effort and obscure the federated plugin architecture:

| Current | Lines | What it is |
|---------|------:|------------|
| `example/desktop/` | ~2,000 | Flutter desktop app (Examples, Visualizer, TSP, Ladder tabs) |
| `example/flutter_web/` | ~2,000 | Flutter web app (similar tabs, VS Code dark theme) |
| `example/native/` | ~96 | Pure Dart CLI demo using `dart_monty_ffi` directly |
| `example/web/` | ~131 | Pure Dart-to-JS demo using JS interop directly |

The two Flutter apps are ~2,000 lines each with nearly identical UI. The
federated plugin is designed so ONE Flutter app automatically picks the
correct backend — having separate desktop and web Flutter apps works against
the architecture.

**Consolidate into a single `example/` Flutter app:**

```text
example/
  lib/
    main.dart                      # One Flutter app, runs on desktop + web
    pages/
      examples_page.dart           # Basic: run, limits, errors
      iterative_page.dart          # External functions, resume/resumeWithError
      futures_page.dart            # Async futures resolution
      ladder_page.dart             # Python ladder showcase (parity proof)
      visualizer_page.dart         # TSP / computation visualization
    widgets/
      code_editor.dart             # Shared code input widget
      result_display.dart          # Shared result display
      console_output.dart          # Shared print output display
  bin/
    native_cli.dart                # Pure Dart CLI demo (no Flutter, ffi only)
  web/
    index.html                     # Web entry with COOP/COEP headers
    coi-serviceworker.js           # SharedArrayBuffer service worker
  test/
    smoke_test.dart                # Verify the demo app builds + basic flow
  pubspec.yaml                     # depends on dart_monty (app-facing package)
```

**What this gives you:**
- **One app proves the architecture** — desktop and web from the same source,
  federated plugin selects the backend automatically
- **Rich snippets** — each page is a self-contained usage pattern that
  context7 can index and agents can reference
- **Ladder showcase** — the ladder tab becomes living documentation of
  cross-platform parity, not just a test artifact
- **Pure Dart stays separate** — `bin/native_cli.dart` demonstrates using
  `dart_monty_ffi` without Flutter (important for CLI/server consumers)
- **Demo IS documentation** — each page has dartdoc explaining the pattern

**What gets deleted:**
- `example/desktop/` — consolidated into unified `example/`
- `example/flutter_web/` — consolidated into unified `example/`
- `spike/web_test/` — retired (spike's job is done; web integration test
  in Slice 6 replaces its validation role)
- `example/web/` — becomes `example/bin/web_cli.dart` or retired if the
  native CLI example is sufficient

**Per-package `example/example.dart` files stay** — pub.dev requires them.
They remain minimal pointers to the main example app.

### Documentation Final Pass

- [ ] All package READMEs match the structured template
- [ ] All per-package `example/example.dart` files are substantive
- [ ] `docs/cookbook.md` written with self-contained recipes
- [ ] `docs/architecture.md` all sections filled (verified during slice reviews)
- [ ] Dartdoc coverage: zero `public_member_api_docs` warnings across all packages
- [ ] `dart doc --validate-links` passes for all packages

### Version Bump + Publish

- [ ] Bump all packages to `0.5.0` in a single commit
- [ ] If package rename decided: create `dart_monty_native`, mark
      `dart_monty_desktop` as discontinued
- [ ] Update all cross-package dependency constraints to `^0.5.0`
- [ ] Publish in dependency order per `CONTRIBUTING.md`
- [ ] Tag release: `v0.5.0`
- [ ] Verify pub.dev pages, dartdoc, and example tabs render correctly
- [ ] Verify context7 indexes the packages (may take a few days)

---

## Net Impact (All Slices + Release Prep Combined)

| Metric | Before | After (est.) |
|--------|-------:|------------:|
| Eliminable lines (refactoring) | — | ~3,500 removed |
| Eliminable lines (demo consolidation) | — | ~2,000 removed (duplicate Flutter app) |
| New docs | 0 | 9 architecture.md sections + cookbook + consolidated demo |
| Bugs fixed | 0 | 1 (`restore()` state divergence — Slice 2) |
| Untested paths covered | 0 | 2 (`_failAllPending` + Flutter web integration) |
| Quality gate scripts | ad-hoc | `tool/gate.sh` + `tool/metrics.sh` |
| DCM in gate | pre-commit only | gate.sh + unused code/files/deps checks |
| Dartdoc enforcement | 1 package | all packages |
| Example apps | 4 (2 duplicate) | 1 unified + 1 CLI |
| Packages touched | — | All 6 Dart + 1 Rust |
| iOS prep | — | `DynamicLibrary.process()` path in FFI |
| Release | — | 0.5.0 (all packages, one event) |
