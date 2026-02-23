# Demo & Showcase Vision

## Approach

The ladder runner and its fixtures **are** the demo for all pure Dart
milestones. No separate Flutter demo app is needed. The existing
native and web ladder runners (`spike/web_test/bin/ladder_runner.dart`
and the native Dart test runner) are extended to handle new fixture
schema fields as milestones land. The JSONL output and cross-path
parity diff prove correctness.

### Layer Classification

| Milestone | Layer | Demo Format |
|-----------|-------|-------------|
| M7A | Pure Dart | Ladder runner (native CLI + Dart web) |
| M13 | Pure Dart | Ladder runner |
| M8 | Pure Dart | Ladder runner |
| M12 | Pure Dart | Ladder runner + interactive Playground (Flutter, later) |
| M7B | Pure Dart | Ladder runner |
| M11 | Pure Dart | Ladder runner |
| M14 | Pure Dart | Ladder runner |
| M15 | Pure Dart | Ladder runner integration tests |
| M9 | Flutter | Flutter example app (platform expansion) |
| M10 | Mixed | Stress tests + benchmark scripts |

**8 of 10 milestones are pure Dart.** Demos use the ladder runner
on both native (CLI via `dart_monty_ffi`) and web (browser via
`dart_monty_wasm`), producing JSONL output that is diffed for parity.

### Design Principles

- **Ladder fixtures are the demo** — Each milestone adds fixtures to
  `test/fixtures/python_ladder/` with new tier files. The runner
  executes them and validates against expected values. xfail is removed
  as features are implemented.
- **Parity proof** — Same fixtures run on native and web. JSONL diff
  proves identical results across paths.
- **No Flutter dependency** — Pure Dart milestones don't require Flutter
  SDK to validate. The ladder runner is a plain Dart program.
- **CI-friendly** — Runner output is structured (JSONL), parseable,
  and suitable for automated gate scripts.

---

## Ladder Runner Extensions

As milestones land, the ladder runner must be extended to handle new
fixture schema fields. This is a critical work item in each milestone.

### New Schema Fields by Milestone

| Milestone | New Fields | Runner Behavior |
|-----------|-----------|-----------------|
| M7A | `expectedKwargs`, `expectedFnName`, `expectedCallId`, `expectedMethodCall`, `expectedExcType`, `expectedTraceback`, `scriptName` | Validate kwargs/callId/methodCall on MontyPending; validate excType and traceback frames on MontyException; pass scriptName to run/start |
| M7B | `limits` (extended: maxAllocations, gcInterval), `expectedPrintLines` | Apply extended limits; collect print output and validate line-by-line |
| M8 | `expectedTypeTag` | Check Dart runtime type and/or type tag on result value |
| M11 | `osCallResponses` | Detect MontyOsCall progress, respond with configured values |
| M12 | `replSteps` | Create MontyRepl, feed each step, validate per-step results |
| M13 | `asyncResumeMap` | Return ExternalResult::Future from sync calls, handle ResolveFutures, resume with map |
| M14 | `typeCheckExpected` | Call typeCheck() before execution, validate diagnostics |

### Runner Architecture

The runner should gracefully skip fixtures with unrecognized fields
(runner doesn't know about `replSteps` → skip that fixture with a
"skip: unsupported field" note). As features land and the runner is
updated, those fixtures transition from skip → xfail → pass.

---

## Fixture Expectations by Milestone

### M7A: Error Fidelity + kwargs + Script Naming

**Tier 8 (kwargs & call metadata)** — IDs 100-108, 9 fixtures

Validates: `expectedKwargs`, `expectedFnName`, `expectedCallId`,
`expectedMethodCall` fields on MontyPending during iterative execution.

| ID | Name | Key Validation |
|----|------|---------------|
| 100 | kwargs simple | kwargs: {query: "hello", limit: 10} |
| 101 | kwargs mixed positional | args[0] + kwargs |
| 102 | kwargs only | All kwargs, no positional |
| 103-108 | ordering, method_call, call_id, value types | See tier 8 spec |

**Tier 9 (exception fidelity)** — IDs 110-121, 12 fixtures

Validates: `expectedExcType` and `expectedTraceback` on MontyException.

| ID | Name | Key Validation |
|----|------|---------------|
| 110-116 | exc_type variants | ValueError, TypeError, KeyError, IndexError, ZeroDivisionError, AttributeError, RecursionError |
| 117-121 | traceback depth | 1-frame, 2-frame, 3-frame, preview_line, filename from scriptName |

**Tier 15 (script naming)** — IDs 190-193, 4 fixtures

Validates: `scriptName` parameter flows to error filenames and tracebacks.

---

### M13: Async / Futures

**Tier 13** — IDs 170-175, 6 fixtures

Validates: `asyncResumeMap` field. Runner must handle `ResolveFutures`
progress variant, correlate call_ids, and resume with mapped values.

| ID | Name | Key Validation |
|----|------|---------------|
| 170 | single await | One future created, one resolved |
| 171 | gather two | Two pending call_ids, both resolved |
| 172 | gather three | Three call_ids |
| 173 | future error | Host returns error, Python sees RuntimeError |
| 174 | mixed sync+async | First call is sync, second is future |
| 175 | nested async | Coroutine chain |

---

### M8: Rich Types

**Tier 10** — IDs 130-144, 15 fixtures

Validates: `expectedTypeTag` field. Runner checks Dart runtime type
matches expected type wrapper.

| ID | Name | Key Validation |
|----|------|---------------|
| 130-131 | tuple identity | $tuple tag on result |
| 132-134 | set/frozenset | $set, $frozenset tags, deduplication |
| 135-137 | bytes | $bytes tag, round-trip |
| 138-140 | namedtuple, dataclass | type_name, field_names, frozen |
| 141-144 | path, large bytes, bigint, mixed | Edge cases |

---

### M12: REPL Sessions

**Tier 12** — IDs 160-168, 9 fixtures

Validates: `replSteps` field. Runner creates MontyRepl, feeds each
step sequentially, validates per-step expected/error.

| ID | Name | Key Validation |
|----|------|---------------|
| 160 | variable persistence | x=10 → x*2 = 20 |
| 161 | function persistence | def f → f(41) = 42 |
| 162 | error recovery | error doesn't destroy session |
| 163-168 | accumulation, import, overwrite, ext fn, snapshot, continuation | See tier 12 spec |

---

### M7B: Print Streaming + Resource Limits

**Tier 14 (resource limits)** — IDs 180-184, 5 fixtures

Validates: `limits` field with extended maxAllocations/gcInterval.

**Tier 16 (print streaming)** — IDs 200-205, 6 fixtures

Validates: `expectedPrintLines` field. Runner collects print output
and validates line-by-line in order.

---

### M11: OS Calls

**Tier 11** — IDs 150-156, 7 fixtures

Validates: `osCallResponses` field. Runner detects MontyOsCall progress,
responds with configured values.

---

### M14: Type Checking

**Tier 17** — IDs 210-215, 6 fixtures

Validates: `typeCheckExpected` field. Runner calls typeCheck() and
validates hasErrors/errorContains before optionally executing.

---

## Flutter Demos (M9, M12 Playground)

Flutter is only required for:

1. **M9 (Platform Expansion)** — Flutter example app validating
   Windows, iOS, Android via the existing Flutter plugin wrappers.

2. **Playground** (after M12 ships) — An interactive REPL widget in
   the Flutter example app where users type Python and see live results.
   This is the one interactive demo that _sells_ the library beyond
   data tables. Not needed for validation — the ladder runner proves
   REPL correctness. The Playground is a showcase/UX artifact.

---

## Parity Proof

Both ladder runners (native CLI and Dart web) execute the same
fixtures and produce JSONL output. The parity diff tool
(`tool/test_cross_path_parity.sh`) compares them field by field.

```text
Native: 125 fixtures, 125 pass, 0 fail
Web:    125 fixtures, 125 pass, 0 fail
Parity: 125/125 identical results ✓
```

This is the strongest cross-platform statement: identical structured
output from the same Python code, through completely different
execution paths (Rust C FFI vs JS NAPI WASM).

---

## Codex Review Findings (Addressed)

These items were flagged during review and must be resolved during
implementation:

### Print Streaming: Polled vs Live (M7B)

M7B allows a "polled per-phase" print strategy as a pragmatic start,
but tier 16 fixtures (IDs 200-205) expect prints to arrive _between_
external call phases. The polled approach satisfies this — prints are
collected after each `run()`/`resume()` call, which occurs at each
phase boundary. True intra-phase streaming (mid-computation) is a
stretch goal, not required by the fixtures.

### REPL feed() Return Type (M12)

`MontyRepl.feed()` returns `MontyObject` (simple evaluation).
`MontyRepl.start()` returns `ReplProgress` (iterative with external
functions). Two separate methods, not one overloaded method. This
mirrors upstream where `MontyRepl::feed` and `MontyRepl::start` are
distinct.

### Async ExternalResult::Future API (M13)

The existing `resume(Object? returnValue)` method is extended: when
the host wants to create a future instead of resolving immediately,
it calls a new `resumeWithFuture()` method. This returns a marker
that the VM interprets as `ExternalResult::Future`. The concrete API:

```dart
// Existing:
progress = await monty.resume(value);        // ExternalResult::Return
progress = await monty.resumeWithError(msg); // ExternalResult::Error
// New:
progress = await monty.resumeWithFuture();   // ExternalResult::Future
// New:
progress = await monty.resolveFutures(Map<int, Object?> results);
```

### Rich Types on Inputs (M8)

M8 focuses on **output** type preservation (Python → Dart). Input
type preservation (Dart → Python, e.g., passing `Uint8List` as
`bytes`) is a separate concern that should be tracked as a follow-up
work item within M8 or as a small addendum.

### Call_id Ordering (Fixtures)

Tier 8 fixture ID 107 asserts sequential call_ids (0, 1, 2). This
assumes upstream monty assigns call_ids sequentially. If upstream
doesn't guarantee ordering, the fixture should validate
_distinctness_ instead of _sequentiality_. Verify upstream behavior
during M7A implementation.

### Ladder Runner Schema Updates

Every milestone that adds new fixture schema fields **must** include
a work item to update both the native and web ladder runners to parse
and validate those fields. This is the most critical implementation
task since the runner IS the demo.
