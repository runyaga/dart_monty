# Native Crate Architecture

The Rust crate (`native/src/`) provides the C FFI layer between Dart and
the `monty` interpreter. Four source files handle the full surface:

- **`handle.rs`** -- `MontyHandle` state machine and execution logic
- **`lib.rs`** -- `extern "C"` FFI entry points
- **`error.rs`** -- panic boundary, C string helpers, exception serialization
- **`convert.rs`** -- `MontyObject` to/from `serde_json::Value` conversion

## Handle Lifecycle

```text
monty_create(code, ext_fns, script_name)
  → MontyHandle { state: Ready(MontyRun), limits: None }

  ┌──── monty_run() ──────────────────────────────────────────┐
  │  Ready → run(tracker, print) → Complete { result_json }   │
  └────────────────────────────────────────────────────────────┘

  ┌──── monty_start() ────────────────────────────────────────┐
  │  Ready → start(tracker, print)                            │
  │    → Complete | Paused{Limited,NoLimit} | Futures{...}    │
  │                                                           │
  │  monty_resume(value_json) / monty_resume_with_error(msg)  │
  │    Paused → snapshot.run(result, print)                   │
  │    → Complete | Paused | Futures                          │
  │                                                           │
  │  monty_resume_as_future()                                 │
  │    Paused → snapshot.run_pending(print)                   │
  │    → Complete | Paused | Futures                          │
  │                                                           │
  │  monty_resume_futures(results_json, errors_json)          │
  │    Futures → snapshot.resume(ext_results, print)          │
  │    → Complete | Paused | Futures                          │
  └────────────────────────────────────────────────────────────┘

monty_free(handle)
  → drop(Box::from_raw(handle))
```

## FFI Boundary Contract

All data crosses the boundary as **JSON strings** (NUL-terminated UTF-8).
Errors use an **out-parameter** pattern: `out_error: *mut *mut c_char`.

- **Rust to Dart strings:** Allocated with `CString::into_raw()`. Dart
  reads and frees via `monty_string_free()`.
- **Dart to Rust strings:** Passed as `*const c_char`, parsed by
  `parse_c_str()` (null check + UTF-8 validation).
- **Progress functions** use the `ffi_progress!` macro which handles:
  handle null check, `catch_ffi_panic` boundary, and error out-parameter
  dispatch -- reducing each FFI function to its essential logic.

## Tracker Abstraction

The `monty` crate is generic over `ResourceTracker` (`LimitedTracker` for
bounded execution, `NoLimitTracker` for unbounded). Since `HandleState`
stores `Snapshot<T>` and `FutureSnapshot<T>`, the enum needs separate
variants for each tracker type (7 total: `Ready`, `PausedLimited`,
`PausedNoLimit`, `FuturesLimited`, `FuturesNoLimit`, `Complete`,
`Consumed`).

The `TrackerExt` trait maps each tracker type to its corresponding
`HandleState` constructors:

```rust
trait TrackerExt: monty::ResourceTracker + Sized {
    fn into_paused(snapshot: Snapshot<Self>, meta: PendingMeta) -> HandleState;
    fn into_futures(snapshot: FutureSnapshot<Self>, call_ids_json: String) -> HandleState;
}
```

This allows a single generic `process_progress<T: TrackerExt>()` method
to handle all `RunProgress` variants, dispatching to the correct
`HandleState` via the trait without duplicating match arms.

## PrintWriter Drain Pattern

Every execution call (`run`, `start`, `resume*`) captures print output
via `PrintWriter::Collect(String::new())`. After the call completes,
`drain_print()` moves the collected string into `self.print_output`.
The `run_snapshot_op()` helper combines this with error dispatch:

```rust
fn run_snapshot_op<T: TrackerExt>(
    &mut self,
    f: impl FnOnce(&mut PrintWriter) -> Result<RunProgress<T>, MontyException>,
) {
    let mut print = PrintWriter::Collect(String::new());
    let result = f(&mut print);
    self.drain_print(print);
    // dispatch Ok(progress) or Err(exc)
}
```

This eliminates the repeated init/drain/match pattern across all resume
methods.
