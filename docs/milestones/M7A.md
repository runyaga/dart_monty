# M7A: Run API Data Model Fidelity

## Goal

Close the data model gaps in the existing Run API. Every field that
upstream monty exposes on `RunProgress::FunctionCall` and
`MontyException` must survive the C FFI / JS bridge and be accessible
from Dart. No new API surfaces — only additive fields on existing types.

## Risk Addressed

- kwargs silently dropped — LLM-generated Python using keyword arguments
  produces empty argument lists on the Dart side
- Exception type indistinguishable — host cannot programmatically handle
  `ValueError` vs `TypeError` without string parsing
- Single-frame tracebacks — no call-chain visibility for debugging
- No call_id — blocks future Async/Futures milestone (M13)
- No script_name — multi-script pipelines produce identical generic filenames

## Dependencies

- M2 (Rust C FFI layer) — must add new C accessor functions
- M4 (WASM package) — must add new JS bridge accessors

## Deliverables

### Platform Interface Changes (`dart_monty_platform_interface`)

- `MontyPending` gains: `kwargs` (`Map<String, Object?>?`), `callId` (`int`),
  `methodCall` (`bool`)
- `MontyException` gains: `excType` (`String`), `traceback`
  (`List<MontyStackFrame>`)
- New model: `MontyStackFrame` with `filename`, `startLine`, `startColumn`,
  `endLine`, `endColumn`, `frameName`, `previewLine`, `hideCaret`,
  `hideFrameName`
- `MontyPlatform.run()` and `start()` gain optional `scriptName` parameter
- JSON `fromJson` factories updated to parse new fields

### Native C FFI Changes (`native/`)

- New C functions: `monty_pending_fn_kwargs_json`, `monty_pending_call_id`,
  `monty_pending_method_call`
- `monty_complete_result_json` error path: include `exc_type` and full
  `traceback` array in JSON
- `monty_create` gains `script_name` parameter (or new
  `monty_create_named` function)

### JS Bridge Changes (`dart_monty_wasm`)

- `MontySnapshot` JS interop: expose `kwargs`, `callId` (from
  upstream `call_id`)
- Error JSON: include `exc_type` string and `traceback` array
- `Monty.create` / `start`: pass `scriptName` through

### FFI Implementation (`dart_monty_ffi`)

- `MontyFfi` reads new C accessors during `start()`/`resume()` cycles
- `MontyFfi.run()` and `start()` pass `scriptName` to native layer

### WASM Implementation (`dart_monty_wasm`)

- `MontyWasm` reads new JS bridge fields
- `MontyWasm.run()` and `start()` pass `scriptName` to JS layer

## Work Items

### 7A.1 Platform Interface Models

- [ ] Add `kwargs`, `callId`, `methodCall` to `MontyPending`
- [ ] Add `excType`, `traceback` to `MontyException`
- [ ] Create `MontyStackFrame` model with full upstream fields
- [ ] Add optional `scriptName` to `MontyPlatform.run()` and `start()`
- [ ] Update `fromJson` factories for all changed models
- [ ] Update `MockMontyPlatform` to support new fields
- [ ] Unit tests for new model fields and JSON round-trips

### 7A.2 Rust C FFI Extensions

- [ ] `monty_pending_fn_kwargs_json(handle) -> *const c_char`
- [ ] `monty_pending_call_id(handle) -> u32`
- [ ] `monty_pending_method_call(handle) -> bool`
- [ ] Extend error JSON to include `exc_type` and `traceback` array
- [ ] Add `script_name` parameter to `monty_create` (or add `monty_create_named`)
- [ ] Rust unit tests for all new accessors
- [ ] `cargo clippy -- -D warnings` clean

### 7A.3 FFI Implementation

- [ ] `NativeBindings` interface: add new accessor signatures
- [ ] `NativeBindingsFfi`: implement new C function calls
- [ ] `MontyFfi`: read kwargs/callId/methodCall during iterative loop
- [ ] `MontyFfi`: parse full traceback from error JSON
- [ ] `MontyFfi`: pass scriptName to native layer
- [ ] Mock-based unit tests (>= 90% coverage)
- [ ] Integration tests with native library

### 7A.4 JS Bridge Extensions

- [ ] Expose kwargs, callId from `MontySnapshot` JS class
- [ ] Extend error response to include excType and traceback
- [ ] Pass scriptName through to `Monty.create`
- [ ] JS bridge unit tests

### 7A.5 WASM Implementation

- [ ] `MontyWasm`: read new JS bridge fields
- [ ] `MontyWasm`: pass scriptName to JS layer
- [ ] Unit tests (>= 90% coverage)

### 7A.6 Ladder Runner Updates

- [ ] Native runner: parse `expectedKwargs`, `expectedFnName`,
      `expectedCallId`, `expectedMethodCall` from fixtures
- [ ] Native runner: parse `expectedExcType`, `expectedTraceback` from fixtures
- [ ] Native runner: parse `scriptName` and pass to run/start
- [ ] Native runner: validate MontyPending fields against expected values
- [ ] Native runner: validate MontyException.excType and traceback frames
- [ ] Web runner: mirror all native runner changes
- [ ] Runner gracefully skips fixtures with unrecognized fields

### 7A.7 Ladder Tests

- [ ] Tier 8 fixtures (kwargs & call metadata): IDs 100-108, remove xfail
- [ ] Tier 9 fixtures (exception fidelity): IDs 110-121, remove xfail
- [ ] Tier 15 fixtures (script naming): IDs 190-193, remove xfail
- [ ] All fixtures pass on both native and web runners
- [ ] JSONL parity verified (native vs web)

## Ladder Tiers Unlocked

| Tier | Name | Fixture IDs | Count |
|------|------|-------------|-------|
| 8 | kwargs & call metadata | 100-108 | 9 |
| 9 | Exception fidelity | 110-121 | 12 |
| 15 | Script naming | 190-193 | 4 |
| | | | **25** |

## Demos Unlocked

- **Demo 3:** Rich Error Diagnostics (full tracebacks + exception types)
- **Demo 4:** Agent Tool Call with Keyword Arguments
- **Demo 11:** Multi-Script Orchestration with Named Error Attribution

### Validation Artifacts

The ladder fixtures (tiers 8, 9, 15) are built and passing as part of
this milestone. Demo applications (3, 4, 11) are identified as showcase
targets but detailed demo design — including web vs desktop platform
choice, UI treatment, and user flow — is deferred to a separate
visioning/planning process after milestone reorganization.

## Dart Layer

**Pure Dart** — no Flutter SDK dependency. Changes touch
`dart_monty_platform_interface`, `native/`, `dart_monty_ffi`, and
`dart_monty_wasm`. Validated by the ladder runner (CLI + web), not a
Flutter app. Flutter plugin wrappers (`dart_monty_desktop`,
`dart_monty_web`) inherit changes automatically.

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS (native FFI) | Full | New C accessors in libdart_monty_native.dylib |
| Linux (native FFI) | Full | Same C API, .so build |
| Web (WASM/JS) | Full | JS bridge updates for kwargs, traceback, scriptName |
| Windows | Deferred | Covered by M9 once C API is extended |
| iOS / Android | Deferred | Covered by M9 once C API is extended |

Both native and web paths must pass all unlocked ladder tiers. JSONL
parity between paths is required.

## Dartdoc

- [ ] Dartdoc comments on all new/changed public fields: `MontyPending.kwargs`,
      `MontyPending.callId`, `MontyPending.methodCall`, `MontyException.excType`,
      `MontyException.traceback`
- [ ] Full dartdoc on new `MontyStackFrame` class and all its fields
- [ ] Document `scriptName` parameter on `run()` and `start()`
- [ ] Code examples in dartdoc: kwargs dispatch, traceback rendering,
      excType switch, multi-script pipeline with scriptName
- [ ] `dart doc` generates cleanly with no warnings for all affected packages

## Quality Gate

```bash
# Platform interface:
cd packages/dart_monty_platform_interface
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test --coverage=coverage

# Rust:
cd native
cargo build --release
cargo test
cargo clippy -- -D warnings
cargo fmt --check

# FFI:
bash tool/test_ffi.sh

# WASM:
bash tool/test_wasm.sh

# Ladder parity:
bash tool/test_python_ladder.sh
bash tool/test_cross_path_parity.sh
```
