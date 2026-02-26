# dart_monty Roadmap

## Completed Milestones

| Milestone | Description | Status |
|-----------|-------------|--------|
| M1 | Platform Interface (pure Dart contract) | Complete |
| M2 | Rust C FFI Layer + WASM Build | Complete |
| M3A | Native FFI Package | Complete |
| M3B | Web Viability Spike | Complete (GO) |
| M3C | Cross-Platform Parity & Python Ladder | Complete |
| M4 | Pure Dart WASM Package | Complete |
| M5 | Flutter Desktop Plugin (macOS + Linux) | Complete |
| M6 | Flutter Web Plugin | Complete |
| M7A | Run API Data Model Fidelity | Complete |

Current version: **0.4.3**. Current API coverage: ~40% of upstream monty surface.

---

## Architecture Refactoring — Phase 1 (Complete)

The codebase underwent a 10-slice refactoring to reduce ~5,500 lines of
duplication, establish quality gates, consolidate tests, and prepare for
platform expansion.

See `docs/refactoring-plan.md` for the full plan.

| Slice | Description | Risk | Status |
|-------|-------------|------|--------|
| 0 | Quality Gate Baseline (`gate.sh`, `metrics.sh`, arch.md skeleton) | None | **Done** |
| 1 | Test Pruning + Trivial Cleanup (~1,394 lines) | Medium | **Done** |
| 2 | Fix `restore()` State Divergence | Low | **Done** |
| 3 | Mock & API Surface Cleanup | Low-Medium | **Done** |
| 4 | State Machine Consolidation (mixin extraction) | Medium | **Done** |
| 5 | Shared Test Harness (contract tests) | Medium | **Done** |
| 6 | Web Package Simplification | **High** | **Done** |
| 7 | Desktop & WASM Refinement + iOS Prep | Low-Medium | **Done** |
| 8 | Rust Crate Consolidation | **Highest** | **Done** |
| 9 | DCM Lint Cleanup | Low | **In Progress** |

Shipped incrementally across **0.4.x** releases.

Recommended order: `0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9`

### Slice Review Process

Each slice goes through this pipeline (full process in `docs/refactoring-plan.md`):

0. **Audit & update spec** — run the prerequisite audit, then update the
   slice spec in `refactoring-plan.md` with findings. Gemini reviews against
   the spec, so stale specs cause false positives.
1. **Run `bash tool/slice_review.sh <N>`** — executes tests, gate checks,
   captures metrics delta vs baseline, generates a unified diff, and
   assembles a review prompt at `ci-review/slice-reviews/slice-N-prompt.md`.
2. **Pass review artifacts to Gemini** — use `mcp__gemini__read_files` with
   the prompt `.md`, changed source files, and the `.diff`, model
   `gemini-3.1-pro-preview`. Use `--context <file>` for unchanged files
   Gemini needs to verify claims about pre-existing code.
3. **Address review findings** — fix any issues Gemini flags, re-run the
   review script if needed, then commit.

Flags: `--skip-tests`, `--skip-gate`, `--skip-all`, `--context <file>`.
Output lands in `ci-review/slice-reviews/`.

---

## Architecture Refactoring — Phase 2

**Goal:** Capability interfaces + `BaseMontyPlatform` + unified bindings
contract. Eliminates ~400 lines of duplication, removes `UnsupportedError`
from web, prepares clean extension points for M13/M12/M14.

**Branch:** `refactor/capability-interfaces`
**Reference:** `docs/refactoring-slices.md` for detailed specs

| Slice | Description | Status |
|-------|-------------|--------|
| 1 | Define Capability Interfaces | Pending |
| 2 | Slim MontyPlatform + Implement Capabilities (atomic) | Pending |
| 3 | Update MockMontyPlatform + LadderRunner | Pending |
| 4 | Define CoreRunResult, CoreProgressResult, MontyCoreBindings | Pending |
| 5 | Create BaseMontyPlatform | Pending |
| 6 | Create FfiCoreBindings Adapter | Pending |
| 7 | Create WasmCoreBindings Adapter | Pending |
| 8 | Migrate MontyFfi to BaseMontyPlatform | Pending |
| 9 | Migrate MontyWasm to BaseMontyPlatform | Pending |
| 10 | Delete Desktop Wrapper Types | Pending |
| 11 | Full-Stack Verification | Pending |

**Ships with:** M13 + M8 as combined **0.5.0** release.

---

## Implementation Order (Prioritized)

Ordered for **maximum API coverage gain per milestone** with primary
focus on the **AI agent tool execution** use case. Milestone numbering
is preserved for reference stability; implementation order diverges
from numbering.

### Phase 1: Agent-Critical Fidelity

| Priority | Milestone | Description | Key Unlock | Status |
|----------|-----------|-------------|------------|--------|
| 1 | M7A | Run API Data Model Fidelity | kwargs, excType, tracebacks, callId, scriptName | **Complete** |
| 2 | Arch Phase 2 | Capability interfaces + BaseMontyPlatform | Clean extension points, ~400 lines removed | **Active** |
| 3 | M13 | Async / Futures | asyncio.gather, concurrent tool calls | Pending |
| 4 | M8 | Rich Type Bridge | $tuple, $set, $bytes, dataclass preservation | Pending |

After arch refactoring completes, M13 and M8 ship. API coverage jumps
to ~55-65%. LLM agents can call tools with kwargs, handle concurrent
async operations, and receive structured data back with type identity
preserved.

**Release: 0.5.0** — Arch refactoring + M13 + M8 ship together as a
single breaking release. This batches the hard API breaks (new sealed
variants on `MontyProgress`, typed return values on `MontyResult.value`)
into one migration for consumers.

### Phase 2: Interactive & Behavioral

| Priority | Milestone | Description | Key Unlock |
|----------|-----------|-------------|------------|
| 5 | M12 | REPL API | Interactive sessions, incremental execution |
| 6 | M7B | Run API Behavioral Extensions | Print streaming, resource limits, runNoLimits |
| 7 | M11 | OS Calls | os.getenv, os.environ, os.stat in sandbox |

After Phase 2: API coverage ~75-85%. Full interactive Python console
possible. Print streaming enables live feedback. OS calls enable
sandboxed environment access.

**Release: 0.6.0** — M11 adds another sealed variant (`MontyOsCall`)
to `MontyProgress`. Batched with M12 and M7B as one breaking release.

### Phase 3: Polish & Expand

| Priority | Milestone | Description | Key Unlock |
|----------|-----------|-------------|------------|
| 8 | M14 | Type Checking | Pre-execution validation, LLM code checking |
| 9 | M15 | Progress Serialization | Suspend/resume across restarts |
| 10 | M9 | Platform Expansion (Windows + Mobile) | iOS, Android, Windows support |
| 11 | M10 | Hardening | Stress tests, benchmarks, snapshot portability |

After Phase 3: API coverage ~95%+. Full platform matrix. Production
hardened. M10 validates the complete, final API surface.

**Release: 0.7.0+** — Soft breaks only (new methods on
`MontyPlatform`). If API is stable, consider 1.0.0 after M10 hardening.

---

## Dependency Graph

```text
Refactoring Phase 1 (Slices 0-9) ── DONE
  └── Refactoring Phase 2 (Capability Interfaces) ── ACTIVE
       ├── M13 (Async/Futures) ← needs MontyFutureCapable
       ├── M8 (Rich Type Bridge) ← benefits from BaseMontyPlatform
       └── all subsequent milestones benefit from clean base

M7A (Data Model Fidelity) ── COMPLETE
 ├── M13 (Async/Futures) ← REQUIRES M7A call_id
 ├── M8 (Rich Type Bridge) ← benefits from stable models
 ├── M12 (REPL) ← benefits from tracebacks, excType
 ├── M7B (Behavioral) ← benefits from stable models
 └── M11 (OS Calls) ← benefits from excType

M14 (Type Checking) ← independent, slot anywhere
M15 (Progress Serialization) ← benefits from M12 for REPL progress
M9 (Platform Expansion) ← orthogonal, parallel track
M10 (Hardening) ← LAST: validates everything
```

---

## Primary Focus: AI Agent Tool Execution

If shipping only 3-4 milestones before release:

**Must-ship:** M7A + M13 + M8

This gives agents:

- kwargs on tool calls (M7A)
- Concurrent async tool execution (M13)
- Structured data round-trips (M8)
- Programmatic error handling via excType (M7A)
- Full tracebacks for LLM self-correction (M7A)

**Strong addition:** M14 (Type Checking) — validate LLM-generated code
before execution, saving cycle time.

---

## Breaking Changes & Versioning

Current version: **0.4.3** (under semver 0.x, minor bumps can break).

### Hard Breaks (compile-time failures for consumers)

| Milestone | Break | Detail |
|-----------|-------|--------|
| M13 | New sealed variant | `MontyResolveFutures` added to sealed `MontyProgress`. Exhaustive `switch` statements break. |
| M8 | Return type changes | `MontyResult.value` returns typed wrappers (`MontyTuple`, `MontySet`, `MontyBytes`, `MontyDataclass`) instead of plain `List`/`Map`. Code doing `value as List` on tuples breaks. |
| M11 | New sealed variant | `MontyOsCall` added to sealed `MontyProgress`. Same exhaustive-switch breakage. |

### Soft Breaks (only affects third-party `MontyPlatform` implementors)

| Milestone | Break | Detail |
|-----------|-------|--------|
| Arch Phase 2 | Methods removed | `MontyPlatform` loses 5 methods. Third-party implementors must add capability interfaces (`MontySnapshotCapable`, `MontyFutureCapable`). |
| M7B | New abstract methods | `setMaxDuration()`, `runNoLimits()`, `checkLargeResult()` on `MontyPlatform` |
| M13 | New abstract methods | `resumeWithFuture()`, `resolveFutures()` on `MontyPlatform` |
| M14 | New abstract method | `typeCheck()` on `MontyPlatform` |
| M15 | New abstract methods | `dumpProgress()`, `loadProgress()` on `MontyPlatform` |

### Release Strategy

All hard breaks are batched into phase releases to minimize consumer churn:

| Release | Phase | Milestones | Breaking? |
|---------|-------|-----------|-----------|
| **0.5.0** | Phase 1 | Arch Phase 2 + M13 + M8 | **Yes** — capability interfaces + sealed variants + typed values |
| **0.6.0** | Phase 2 | M12 + M7B + M11 | **Yes** — sealed variant (MontyOsCall) |
| **0.7.0+** | Phase 3 | M14 + M15 + M9 + M10 | Soft only |

---

## Risks

| Milestone | Risk | Mitigation |
|-----------|------|------------|
| M8 | Upstream C FFI may flatten type tags ($tuple, $set) before we see them | Investigate Rust serialization path early; may need upstream PR |
| M13 | Deadlocks if ResolveFutures map drops a call_id | Timeout handling on Dart side; robust error propagation |
| M14 | monty-type-checking crate may add 10MB+ to WASM payload | Feature flag in Cargo.toml; consider web-only exclusion |
| M15 | Cross-architecture snapshot portability unlikely (ARM64 <-> x86_64 <-> WASM) | Document constraints; same-platform restore only |
| M8 | Bytes via JSON integer arrays causes 4x bloat | Binary transfer path (monty_complete_result_bytes) |

---

## Demo Strategy

See `docs/demo-vision.md` for full specification.

- **Ladder runner is the demo** — No separate Flutter app for pure Dart
  milestones. The native and web ladder runners execute fixtures and
  produce JSONL output. Parity diff proves cross-platform correctness.
- **8 of 10 milestones are pure Dart** — no Flutter SDK dependency.
  Only M9 (platform expansion) and M10 (hardening) require Flutter.
- **Runner extended per milestone** — Each milestone adds fixture schema
  fields and corresponding runner validation logic. This is the critical
  implementation path.
- **Flutter Playground** — One interactive REPL widget added to the
  Flutter example app when M12 ships. Showcase artifact, not validation.

### Layer Classification

| Milestone | Layer | Demo Format |
|-----------|-------|-------------|
| M7A | Pure Dart | Ladder runner (CLI + web) |
| M13 | Pure Dart | Ladder runner |
| M8 | Pure Dart | Ladder runner |
| M12 | Pure Dart | Ladder runner + Flutter Playground (later) |
| M7B | Pure Dart | Ladder runner |
| M11 | Pure Dart | Ladder runner |
| M14 | Pure Dart | Ladder runner |
| M15 | Pure Dart | Integration tests |
| M9 | Flutter | Flutter example app |
| M10 | Mixed | Stress tests + benchmarks |

---

## Fixture Coverage

| Phase | Milestones | Ladder Tiers | Fixtures | Cumulative |
|-------|-----------|-------------|----------|------------|
| Existing | M1-M6 | 1-7 | 46 | 46 |
| Phase 1 | M7A, M13, M8 | 8, 9, 10, 13, 15 | 46 | 92 |
| Phase 2 | M12, M7B, M11 | 11, 12, 14, 16 | 27 | 119 |
| Phase 3 | M14, M15 | 17 | 6 | 125 |

---

## Backlog

Items to investigate or address in future milestones:

- **method_call == true test gap (M7A.2):** No integration test verifies
  `monty_pending_method_call` returns `1` (true). Current tests only
  cover `0` (function call) and `-1` (wrong state). Investigate whether
  upstream monty emits `method_call: true` for `obj.ext_fn()` syntax on
  external functions. If supported, add a test; otherwise document as a
  known limitation.

- **Snapshot serialization performance:** The worker's base64 encoding
  uses `String.fromCharCode` in a loop + `btoa`, which works but may
  hit V8 string length limits for multi-MB snapshots. Consider chunked
  `fromCharCode` or a `FileReaderSync` Blob approach if perf degrades.

- **WASM async/futures blocked on upstream API (M13):** The
  `@pydantic/monty` NAPI-RS WASM module does not expose the low-level
  `FutureSnapshot` API or `ExternalResult::Future` variant to JS
  consumers. Capability interfaces (`MontyFutureCapable`) cleanly solve
  the Dart-side API problem — platforms that don't support futures simply
  don't implement the interface, avoiding `UnsupportedError`. The upstream
  limitation remains: NAPI-RS wraps async internally via `runCodeAsync(code,
  awaitHandler)`, hiding the `ResolveFutures` state machine. Consider
  opening a feature request on `pydantic/monty` for low-level futures
  control.

- **Arena-based FFI memory safety:** Deferred from architecture
  refactoring Phase 2 because `NativeBindingsFfi` is explicitly
  untouched. Address in a follow-up slice when modifying
  `NativeBindingsFfi`.
