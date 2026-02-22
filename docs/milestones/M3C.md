# M3C: Cross-Platform Parity and Python Ladder

**Status:** Complete

## Goal

Exhaustive cross-platform testing: identical Python code must produce
identical results on native FFI and WASM paths. Snapshot portability
between native and WASM.

## Prerequisites

- M3A (Native FFI package) complete
- M3B (Web spike) passes GO decision

## Architecture

### Test Execution Paths

```text
                    ┌─────────────────────────────────┐
                    │  test/fixtures/python_ladder/    │
                    │  JSON fixtures (6 tiers)         │
                    └──────────┬──────────┬────────────┘
                               │          │
               ┌───────────────┘          └───────────────┐
               ▼                                          ▼
   ┌───────────────────────┐              ┌───────────────────────────┐
   │   Native Ladder        │              │   Web Ladder               │
   │                        │              │                            │
   │   Dart test / runner   │              │   Dart compiled to JS      │
   │         │              │              │         │                  │
   │         ▼              │              │         ▼                  │
   │   MontyFfi (dart:ffi)  │              │   montyBridge (JS interop) │
   │         │              │              │         │                  │
   │         ▼              │              │         ▼                  │
   │   libdart_monty_native  │              │   Web Worker               │
   │   (Rust shared lib)    │              │         │                  │
   │         │              │              │         ▼                  │
   │         ▼              │              │   @pydantic/monty WASM     │
   │   Monty interpreter    │              │   (wasm32-wasi)            │
   └───────────────────────┘              └───────────────────────────┘
               │                                          │
               ▼                                          ▼
        JSONL output                               JSONL output
     /tmp/parity_native.jsonl               /tmp/parity_web.jsonl
               │                                          │
               └──────────────┬───────────────────────────┘
                              ▼
                    Python diff script
                    (per-fixture MATCH/MISMATCH)
```

### Native Path

`Dart → MontyFfi → dart:ffi → libdart_monty_native.dylib/so → Monty Rust`

- `python_ladder_test.dart` — `dart test --tags=ladder` (CI-friendly)
- `python_ladder_runner.dart` — `dart <file>` standalone JSONL output

### Web Path

`Dart → dart:js_interop → monty_glue.js → Web Worker → @pydantic/monty WASM`

- `ladder_runner.dart` — compiled to JS via `dart compile js`
- Served with COOP/COEP headers (required for SharedArrayBuffer)
- Run in headless Chrome, JSONL extracted from console logs

### Parity Verification

The parity gate (`test_cross_path_parity.sh`) runs both paths, captures
JSONL output, and uses a Python script to compare per-fixture results.
Values are compared via `json.dumps(sort_keys=True)` for order-independent
equality.

## Deliverables

### 1. JSON Test Fixtures

Located in `test/fixtures/python_ladder/`:

| File | Tier |
|------|------|
| `tier_01_expressions.json` | Expressions |
| `tier_02_variables.json` | Variables & Collections |
| `tier_03_control_flow.json` | Control Flow |
| `tier_04_functions.json` | Functions |
| `tier_05_errors.json` | Error Handling |
| `tier_06_external_fns.json` | External Functions |

### 2. Native Ladder Runner

- `packages/dart_monty_ffi/test/integration/python_ladder_test.dart` —
  Tagged `@Tags(['integration', 'ladder'])`, runs all fixtures via MontyFfi
- `packages/dart_monty_ffi/test/integration/python_ladder_runner.dart` —
  Standalone JSONL runner for parity comparison

### 3. Web Ladder Runner

- `spike/web_test/bin/ladder_runner.dart` — Dart compiled to JS, uses
  montyBridge JS interop to run fixtures in headless Chrome
- `spike/web_test/web/ladder_runner.html` — HTML host page

### 4. Worker Extension

Added `resumeWithError` support to the web worker:

- `spike/web_test/web/monty_worker_src.js` — `handleResumeWithError()`
- `spike/web_test/web/monty_glue.js` — `resumeWithError()` bridge method

### 5. Gate Scripts

| Script | Purpose |
|--------|---------|
| `tool/test_python_ladder.sh` | Runs all fixtures on both paths |
| `tool/test_cross_path_parity.sh` | JSONL diff between native and web |
| `tool/test_snapshot_portability.sh` | Exploratory snapshot portability |

## Fixture Schema

```json
{
  "id": 1,
  "tier": 1,
  "name": "int addition",
  "code": "2 + 2",
  "expected": 4,
  "expectedContains": null,
  "expectedSorted": false,
  "expectError": false,
  "errorContains": null,
  "externalFunctions": null,
  "resumeValues": null,
  "resumeErrors": null,
  "nativeOnly": false
}
```

**Match fields:**

- `expected` — exact JSON equality (via `jsonEncode` comparison)
- `expectedContains` — substring match on stringified value
- `expectedSorted` — sort arrays before compare (unordered collections)
- `expectError` + `errorContains` — expect MontyException
- `externalFunctions` + `resumeValues` — iterative start/resume flow
- `resumeErrors` — iterative start/resumeWithError flow

## Quality Gate

```bash
bash tool/test_python_ladder.sh
bash tool/test_cross_path_parity.sh
bash tool/test_snapshot_portability.sh
```

## Findings

### Snapshot Portability

- Native-to-native round-trip: works (verified in M3A smoke tests)
- Cross-platform binary portability (native Rust ↔ WASM): not guaranteed —
  native uses bincode serialization, WASM uses in-memory objects
- Full cross-platform snapshot restore through web Worker deferred to M4

### Python Compatibility Ladder

| Tier | Feature | Status |
|------|---------|--------|
| 1 | Expressions | Tested |
| 2 | Variables and collections | Tested |
| 3 | Control flow | Tested |
| 4 | Functions | Tested |
| 5 | Error handling | Tested |
| 6 | External functions | Tested |
| 7+ | Classes, async, etc. | Future milestones |
