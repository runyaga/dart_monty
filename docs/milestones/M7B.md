# M7B: Run API Behavioral Extensions

## Goal

Add behavioral capabilities to the existing Run API: live print streaming,
fine-grained resource limits, and a no-limits fast path. These involve new
callback mechanisms and parameter additions rather than purely additive
data model fields.

## Risk Addressed

- Print output only available after execution completes — no real-time
  feedback during long-running Python code
- Missing allocation cap (`max_allocations`) leaves a DoS vector in
  multi-tenant sandboxes
- Time limits cannot be re-armed between external call phases —
  wall-clock time for host I/O counts against the Python budget
- No fast path for trusted code — every execution pays tracking overhead

## Dependencies

- M7A (data model fidelity) — should land first so all model changes
  are stabilized before adding behavioral features
- M2 (Rust C FFI layer)
- M4 (WASM package)

## Deliverables

### Platform Interface Changes (`dart_monty_platform_interface`)

- `MontyPlatform.run()` and `start()` gain optional `onPrint` callback
  (`void Function(String)?`)
- `MontyLimits` gains: `maxAllocations` (`int?`), `gcInterval` (`int?`)
- New method: `MontyPlatform.setMaxDuration(Duration)` for re-arming
  time limits between iterative phases
- New method: `MontyPlatform.runNoLimits(code, {inputs, scriptName})` —
  skip tracker setup, still enforces recursion depth 1000
- New method: `MontyPlatform.checkLargeResult(int estimatedBytes)` —
  preflight size check before returning large results (from
  `ResourceTracker::check_large_result`)

### Native C FFI Changes (`native/`)

- New C function: `monty_set_print_callback(handle, callback_fn_ptr)` or
  extend `monty_create` to accept a print callback
- Alternatively: `monty_get_print_output(handle) -> *const c_char` called
  after each resume (simpler, no callback across FFI boundary)
- `monty_set_max_allocations(handle, count)`
- `monty_set_gc_interval(handle, interval)`
- `monty_set_max_duration_ms(handle, ms)` — re-arm time limit
- `monty_run_no_limits(handle, code, ...) -> *const c_char`

### JS Bridge Changes (`dart_monty_wasm`)

- Print streaming via Worker messages: Worker sends `{type: "print",
  text: "..."}` messages during execution
- Main thread collects print messages and delivers to Dart callback
- Resource limit fields passed through to `Monty.create` options

### Implementations

- `MontyFfi` and `MontyWasm` implement new platform interface methods
- Print callback plumbing through Isolate (desktop) and Worker (web)

## Work Items

### 7B.1 Platform Interface

- [ ] Add `onPrint` callback to `run()` and `start()` signatures
- [ ] Add `maxAllocations`, `gcInterval` to `MontyLimits`
- [ ] Add `setMaxDuration(Duration)` method to `MontyPlatform`
- [ ] Add `runNoLimits()` method to `MontyPlatform`
- [ ] Update `MockMontyPlatform`
- [ ] Unit tests for new parameters and methods

### 7B.2 Rust C FFI Extensions

- [ ] Print output collection: `PrintWriter::Collect` per-phase or
      `PrintWriter::Callback` with C function pointer
- [ ] `monty_set_max_allocations(handle, count)`
- [ ] `monty_set_gc_interval(handle, interval)`
- [ ] `monty_set_max_duration_ms(handle, ms)`
- [ ] `monty_run_no_limits` entry point using `NoLimitTracker`
- [ ] `monty_check_large_result(handle, estimated_bytes) -> bool` —
      preflight size check before returning large results
- [ ] Rust unit tests
- [ ] `cargo clippy -- -D warnings` clean

### 7B.3 FFI Implementation

- [ ] `NativeBindings`: add new C function signatures
- [ ] `NativeBindingsFfi`: implement calls
- [ ] `MontyFfi`: collect print output per-phase, deliver to callback
- [ ] `MontyFfi`: pass new limit fields to native layer
- [ ] `MontyFfi.setMaxDuration()` implementation
- [ ] `MontyFfi.runNoLimits()` implementation
- [ ] Mock-based unit tests (>= 90% coverage)
- [ ] Integration tests

### 7B.4 JS Bridge & WASM Implementation

- [ ] Worker: send print messages during execution
- [ ] Main thread: collect and deliver to Dart callback
- [ ] Pass resource limit fields through to Monty.create
- [ ] `MontyWasm.setMaxDuration()` implementation
- [ ] `MontyWasm.runNoLimits()` implementation
- [ ] Unit tests (>= 90% coverage)

### 7B.5 Flutter Plugin Updates

- [ ] `dart_monty_native`: plumb `onPrint` through Isolate message channel
- [ ] `dart_monty_web`: plumb `onPrint` through Worker messages
- [ ] Integration tests for print streaming in both plugins

### 7B.6 Ladder Runner Updates

- [ ] Native runner: parse `limits` field with extended maxAllocations,
      gcInterval and apply to execution
- [ ] Native runner: parse `expectedPrintLines` and collect print output
      per-phase for validation
- [ ] Web runner: mirror all native runner changes

### 7B.7 Ladder Tests

- [ ] Tier 14 fixtures (resource limits): IDs 180-184, remove xfail
- [ ] Tier 16 fixtures (print streaming): IDs 200-205, remove xfail
- [ ] All fixtures pass on both native and web runners
- [ ] JSONL parity verified

## Ladder Tiers Unlocked

| Tier | Name | Fixture IDs | Count |
|------|------|-------------|-------|
| 14 | Resource limits | 180-184 | 5 |
| 16 | Print streaming | 200-205 | 6 |
| | | | **11** |

## Demos Unlocked

- **Demo 6:** Live Execution Streaming with Real-Time Print Output
- **Demo 9:** Multi-Tenant Resource Budgets (fine-grained limits)

### Validation Artifacts

The ladder fixtures (tiers 14, 16) are built and passing as part of
this milestone. Demo applications (6, 9) are identified as showcase
targets but detailed demo design — including web vs desktop platform
choice, UI treatment, and user flow — is deferred to a separate
visioning/planning process after milestone reorganization.

## Design Decisions

### Print Streaming Strategy

Two approaches for native FFI:

1. **Callback across FFI boundary** — `PrintWriter::Callback` with a C
   function pointer. Most efficient but complex: requires `dart:ffi`
   `NativeCallable` and careful lifetime management.

2. **Polled per-phase** — Use `PrintWriter::Collect` and read accumulated
   output after each `run()`/`resume()` call. Simpler but print output
   only arrives at external function call boundaries, not truly real-time.

Decision deferred to implementation. Option 2 is a pragmatic start;
option 1 can be added later if real-time streaming is demanded.

### run_no_limits Scope

`MontyRun::run_no_limits` uses `NoLimitTracker` which still enforces
recursion depth (1000). This is not "unlimited" — it skips memory/time
tracking overhead but retains stack safety. The Dart API should document
this clearly.

## Dart Layer

**Pure Dart** (core). Print streaming, resource limits, and runNoLimits
are implemented in `dart_monty_platform_interface`, `dart_monty_ffi`,
and `dart_monty_wasm` without Flutter. Flutter plugin plumbing
(`onPrint` through Isolate/Worker) is additive. Validated by the ladder
runner (CLI + web).

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS (native FFI) | Full | Print via PrintWriter::Callback or polled Collect; new limit C functions |
| Linux (native FFI) | Full | Same C API, .so build |
| Web (WASM/JS) | Full | Print via Worker postMessage; limits through Monty.create options |
| Windows | Deferred | Covered by M9 |
| iOS / Android | Deferred | Covered by M9 |

**Platform-specific considerations:**
- Native print streaming: C function pointer callback or polled per-phase
  (see Design Decisions). Isolate boundary adds one hop.
- Web print streaming: Worker sends `{type: "print", text: "..."}` messages
  naturally. Latency depends on main thread message processing.

## Dartdoc

- [ ] Dartdoc comments on `onPrint` callback parameter
- [ ] Dartdoc on new `MontyLimits` fields: `maxAllocations`, `gcInterval`
- [ ] Dartdoc on `setMaxDuration()` method with usage guidance
- [ ] Dartdoc on `runNoLimits()` — document that recursion depth 1000
      is still enforced
- [ ] Code examples: print streaming in Flutter, tiered resource budgets,
      time limit re-arming between phases
- [ ] `dart doc` generates cleanly with no warnings

## Quality Gate

```bash
bash tool/test_platform_interface.sh
bash tool/test_ffi.sh
bash tool/test_wasm.sh
bash tool/test_python_ladder.sh
bash tool/test_cross_path_parity.sh
```
