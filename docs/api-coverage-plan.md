# dart_monty API Coverage Plan

## 1. Upstream monty Surface Area

pydantic/monty is a sandboxed Python interpreter written in Rust, designed
for AI agent tool execution. It provides six major API surfaces plus
serialization of in-flight execution state.

### 1.1 Run API (stateless, single-shot execution)

The primary entry point for executing self-contained Python scripts.

| Rust Type | Purpose |
|-----------|---------|
| `MontyRun` | Compiles Python source; holds bytecode for repeated execution |
| `RunProgress<T>` | Enum yielded during iterative execution |
| `Snapshot<T>` | Paused execution state at an external call boundary |
| `ExternalResult` | Host response: `Return(MontyObject)`, `Error(MontyException)`, or `Future` |
| `PrintWriter` | Output capture: `Disabled`, `Stdout`, `Collect(String)`, `Callback(...)` |

**Key methods:**

```rust
MontyRun::new(code, script_name, input_names, external_functions) -> Result<Self, MontyException>
MontyRun::run(&self, inputs, tracker, print) -> Result<MontyObject, MontyException>
MontyRun::run_no_limits(&self, inputs) -> Result<MontyObject, MontyException>
MontyRun::start<T>(self, inputs, tracker, print) -> Result<RunProgress<T>, MontyException>
MontyRun::dump(&self) -> Result<Vec<u8>>
MontyRun::load(bytes) -> Result<Self>
MontyRun::code(&self) -> &str

Snapshot::run(self, result, print) -> Result<RunProgress<T>, MontyException>
Snapshot::run_pending(self, print) -> Result<RunProgress<T>, MontyException>
Snapshot::tracker_mut(&mut self) -> &mut T

RunProgress::dump(&self) -> Result<Vec<u8>>   // serialize in-flight state
RunProgress::load(bytes) -> Result<Self>       // restore in-flight state
```

> **Note:** `MontyRun::run()` takes `&self` (non-consuming) and cannot
> handle external function calls — use `start()`/`resume()` for those.
> The JS bindings implement this workaround internally; Dart should
> mirror it.

**RunProgress variants:**

| Variant | Meaning |
|---------|---------|
| `FunctionCall { function_name, args, kwargs, call_id, method_call, state }` | Paused at external function call |
| `OsCall { function, args, kwargs, call_id, state }` | Paused at OS operation |
| `ResolveFutures(FutureSnapshot<T>)` | Paused waiting for async futures |
| `Complete(MontyObject)` | Execution finished |

### 1.2 REPL API (stateful, incremental execution)

Maintains persistent heap and namespace across multiple code snippets.

| Rust Type | Purpose |
|-----------|---------|
| `MontyRepl<T>` | Stateful session; variables survive across `feed()` calls |
| `ReplProgress<T>` | Same shape as `RunProgress` but returns the REPL for reuse |
| `ReplSnapshot<T>` | Paused REPL state at external call boundary |
| `ReplFutureSnapshot<T>` | Paused REPL state waiting for async futures |
| `ReplStartError<T>` | Error that preserves REPL state for recovery |
| `ReplContinuationMode` | Parse state: `Complete`, `IncompleteImplicit`, `IncompleteBlock` |

**Key methods:**

```rust
MontyRepl::new(code, script_name, inputs, ext_fns, ...) -> Result<(Self, MontyObject), MontyException>
MontyRepl::start(self, code, print) -> Result<ReplProgress<T>, Box<ReplStartError<T>>>
MontyRepl::feed(&mut self, code, print) -> Result<MontyObject, MontyException>
MontyRepl::dump(&self) -> Result<Vec<u8>>
MontyRepl::load(bytes) -> Result<Self>

ReplSnapshot::run(self, result, print) -> Result<ReplProgress<T>, Box<ReplStartError<T>>>
ReplSnapshot::run_pending(self, print) -> Result<ReplProgress<T>, Box<ReplStartError<T>>>

ReplProgress::dump(&self) -> Result<Vec<u8>>   // serialize in-flight REPL state
ReplProgress::load(bytes) -> Result<Self>       // restore in-flight REPL state

detect_repl_continuation_mode(source) -> ReplContinuationMode
```

> **Note:** `MontyRepl::new()` also requires `inputs`, a
> `ResourceTracker`, and a `PrintWriter` — the REPL session is fully
> resource-tracked from initialization.

### 1.3 Async / Futures API

Cooperative multitasking where the host acts as the event loop.

| Rust Type | Purpose |
|-----------|---------|
| `FutureSnapshot<T>` | VM paused waiting on external futures (run API) |
| `ReplFutureSnapshot<T>` | VM paused waiting on external futures (REPL API) |
| `MontyFuture` | Marker type for `ExternalResult::Future` |

**Key methods:**

```rust
FutureSnapshot::pending_call_ids(&self) -> &[u32]
FutureSnapshot::resume(self, results: Vec<(u32, ExternalResult)>, print) -> Result<RunProgress<T>>

ReplFutureSnapshot::pending_call_ids(&self) -> &[u32]
ReplFutureSnapshot::resume(self, results: Vec<(u32, ExternalResult)>, print) -> Result<ReplProgress<T>>
```

**Flow:** Host returns `ExternalResult::Future` from a function call ->
Python code `await`s the future -> VM yields `ResolveFutures` when all
tasks are blocked -> host resolves futures -> VM resumes.

### 1.4 Resource Tracking

| Rust Type | Purpose |
|-----------|---------|
| `ResourceTracker` (trait) | Interface for allocation/time/recursion checking |
| `ResourceLimits` | Builder for configuring limits |
| `LimitedTracker` | Production tracker enforcing limits |
| `NoLimitTracker` | No memory/time limits, but still enforces recursion depth (1000) |
| `ResourceError` | Enum: `Allocation`, `Time`, `Memory`, `Recursion`, `Exception` |

**Additional public methods:**

```rust
LimitedTracker::set_max_duration(&mut self, duration: Duration)  // re-arm time limit between phases
ResourceTracker::check_large_result(&self, estimated_bytes) -> Result<(), ResourceError>
```

**ResourceLimits fields:**

| Field | Type | Description |
|-------|------|-------------|
| `max_allocations` | `usize` | Max heap allocations |
| `max_duration` | `Duration` | Max wall-clock time |
| `max_memory` | `usize` | Max memory in bytes |
| `gc_interval` | `usize` | Allocations between GC sweeps |
| `max_recursion_depth` | `Option<usize>` | Stack depth limit (default 1000) |

### 1.5 Type System & Data Representation

**MontyObject variants:**

| Variant | Rust Payload | Python Type |
|---------|-------------|-------------|
| `None` | — | `None` |
| `Ellipsis` | — | `...` |
| `Bool(bool)` | `bool` | `bool` |
| `Int(i64)` | `i64` | `int` |
| `BigInt(BigInt)` | `num_bigint::BigInt` | `int` (arbitrary precision) |
| `Float(f64)` | `f64` | `float` |
| `String(String)` | `String` | `str` |
| `Bytes(Vec<u8>)` | `Vec<u8>` | `bytes` |
| `List(Vec<Self>)` | `Vec<MontyObject>` | `list` |
| `Tuple(Vec<Self>)` | `Vec<MontyObject>` | `tuple` |
| `NamedTuple { type_name, field_names, values }` | structured | `namedtuple` |
| `Dict(DictPairs)` | ordered k/v pairs | `dict` |
| `Set(Vec<Self>)` | `Vec<MontyObject>` | `set` |
| `FrozenSet(Vec<Self>)` | `Vec<MontyObject>` | `frozenset` |
| `Exception { exc_type, arg }` | `ExcType` + message | exception object |
| `Type(Type)` | type marker | `type` |
| `BuiltinFunction(...)` | function marker | built-in function |
| `Path(String)` | `String` | `pathlib.Path` |
| `Dataclass { name, type_id, field_names, attrs, frozen }` | structured | `@dataclass` |
| `Repr(String)` | display string | non-serializable repr |
| `Cycle(HeapId, String)` | cycle marker | circular reference |

**MontyException:**

```rust
MontyException::exc_type(&self) -> ExcType
MontyException::message(&self) -> Option<&str>
MontyException::traceback(&self) -> &[StackFrame]
MontyException::summary(&self) -> String
MontyException::py_repr(&self) -> String
```

**StackFrame:**

```rust
pub struct StackFrame {
    pub filename: String,
    pub start: CodeLoc,      // { line: u16, column: u16 }
    pub end: CodeLoc,
    pub frame_name: Option<String>,
    pub preview_line: Option<String>,
    pub hide_caret: bool,
    pub hide_frame_name: bool,
}
```

**ExcType variants:** `Exception`, `BaseException`, `SystemExit`,
`KeyboardInterrupt`, `ArithmeticError`, `OverflowError`,
`ZeroDivisionError`, `LookupError`, `IndexError`, `KeyError`,
`RuntimeError`, `NotImplementedError`, `RecursionError`,
`AttributeError`, `FrozenInstanceError`, `NameError`,
`UnboundLocalError`, `ValueError`, `UnicodeDecodeError`, `ImportError`,
`ModuleNotFoundError`, `OSError`, `FileNotFoundError`,
`FileExistsError`, `IsADirectoryError`, `NotADirectoryError`,
`AssertionError`, `MemoryError`, `StopIteration`, `SyntaxError`,
`TimeoutError`, `TypeError`

### 1.6 Built-in Python Functions

`abs`, `all`, `any`, `bin`, `chr`, `divmod`, `enumerate`, `hash`,
`hex`, `id`, `isinstance`, `len`, `map`, `max`, `min`, `next`, `oct`,
`ord`, `pow`, `print`, `repr`, `reversed`, `round`, `sorted`, `sum`,
`type`, `zip`

Type constructors: `bool`, `bytearray`, `bytes`, `complex`, `dict`,
`float`, `frozenset`, `int`, `list`, `memoryview`, `object`, `range`,
`set`, `str`, `tuple`

### 1.7 Standard Library Modules

| Module | Status |
|--------|--------|
| `sys` | Supported (`platform`, `stdout`, `stderr`, `version`, `version_info`) |
| `typing` | Supported (type hints) |
| `asyncio` | Supported (`gather`, coroutine scheduling) |
| `pathlib` | Supported (`Path` class) |
| `os` | Supported (sandboxed: yields `OsCall` to host for `environ`, `getenv`, `stat`, `dir_stat`, `file_stat`, `symlink_stat`) |
| `dataclasses` | Coming soon |
| `json` | Coming soon |

### 1.8 JavaScript Bindings (monty-js / NAPI)

| Class | Methods |
|-------|---------|
| `Monty` | `create`, `run`, `start`, `dump`, `load`, `typeCheck(prefixCode?)`, `repr`, getters: `scriptName`, `inputs`, `externalFunctions` |
| `MontyRepl` | `create`, `feed`, `dump`, `load`, getter: `scriptName`, `repr` |
| `MontySnapshot` | `resume`, `dump`, `load`, getters: `scriptName`, `functionName`, `args`, `kwargs`, `repr` |
| `MontyComplete` | getter: `output`, `repr` |

---

## 2. What dart_monty Currently Supports

### 2.1 Platform Interface (`MontyPlatform`)

| Method | Maps To | Status |
|--------|---------|--------|
| `run(code, inputs, limits)` | `MontyRun::new` + `MontyRun::run` (no external functions) | Supported |
| `start(code, inputs, externalFunctions, limits)` | `MontyRun::new` + `MontyRun::start` | Supported |
| `resume(returnValue)` | `Snapshot::run(ExternalResult::Return)` | Supported |
| `resumeWithError(errorMessage)` | `Snapshot::run(ExternalResult::Error)` | Supported |
| `snapshot()` | `MontyRun::dump` | Supported |
| `restore(data)` | `MontyRun::load` | Supported |
| `dispose()` | Drop `MontyHandle` | Supported |

### 2.2 Data Models

| Dart Model | Maps To | Coverage |
|------------|---------|----------|
| `MontyResult` | `RunProgress::Complete` + tracker stats | `value`, `error`, `usage`, `printOutput` |
| `MontyException` | `MontyException` (Rust) | `message`, `filename`, `lineNumber`, `columnNumber`, `sourceCode` (maps to `StackFrame::preview_line`) — **single frame only** |
| `MontyProgress` | `RunProgress<T>` | `MontyComplete` and `MontyPending` variants |
| `MontyPending` | `RunProgress::FunctionCall` | `functionName`, `arguments` — **no kwargs, call_id, method_call** |
| `MontyLimits` | `ResourceLimits` | `memoryBytes`, `time`, `stackDepth` |
| `MontyResourceUsage` | `LimitedTracker` stats | `memoryBytesUsed`, `timeElapsedMs`, `stackDepthUsed` |

### 2.3 Implementations

| Package | Backend | Platform |
|---------|---------|----------|
| `dart_monty_ffi` | `dart:ffi` -> C FFI -> Rust `MontyRun` | Desktop (macOS, Linux) |
| `dart_monty_wasm` | `dart:js_interop` -> monty-js NAPI -> WASM | Web (Chrome) |
| `dart_monty_desktop` | Flutter plugin wrapping `dart_monty_ffi` via Isolate | Flutter desktop |
| `dart_monty_web` | Flutter plugin wrapping `dart_monty_wasm` | Flutter web |

### 2.4 Native C FFI Functions (17 functions)

```text
monty_create, monty_free, monty_run,
monty_start, monty_resume, monty_resume_with_error,
monty_pending_fn_name, monty_pending_fn_args_json,
monty_complete_result_json, monty_complete_is_error,
monty_snapshot, monty_restore,
monty_set_memory_limit, monty_set_time_limit_ms, monty_set_stack_limit,
monty_string_free, monty_bytes_free
```

---

## 3. What dart_monty Does NOT Support

### 3.1 Missing API Surfaces

| Gap | Upstream Feature | Impact |
|-----|-----------------|--------|
| **REPL API** | `MontyRepl`, `ReplProgress`, `feed()`, session persistence | Cannot build interactive Python consoles or incremental execution sessions |
| **Async / Futures** | `RunProgress::ResolveFutures`, `FutureSnapshot`, `ExternalResult::Future` | Cannot support Python `async`/`await` or concurrent external calls |
| **OS Calls** | `RunProgress::OsCall`, `OsFunction` (`GetEnviron`, `Getenv`) | Python `os.environ` / `os.getenv()` calls will fail |
| **Type Checking** | JS: `Monty.typeCheck(prefixCode?)`, Rust: `monty-type-checking` crate | No static analysis before execution |
| **Live Print Streaming** | `PrintWriter::Callback`, `PrintWriter::Stdout` | Print output only available after execution completes, not in real-time |

### 3.2 Missing Data Fidelity

| Gap | Detail |
|-----|--------|
| **kwargs** | `MontyPending` drops keyword arguments entirely; only positional `args` are exposed |
| **call_id** | External call identifier not exposed; prevents future correlation for async |
| **method_call** | Boolean flag distinguishing `obj.method()` from `func()` not exposed |
| **Full tracebacks** | Only top stack frame exposed (`filename`, `lineNumber`); full `Vec<StackFrame>` with `frame_name`, `start`/`end` locations, preview lines are lost |
| **Exception types** | `ExcType` enum (ValueError, TypeError, etc.) merged into message string; cannot programmatically distinguish exception types |
| **NamedTuple** | Collapses to generic `Map`; `type_name` and `field_names` lost |
| **Dataclass** | Collapses to generic `Map`; `name`, `type_id`, `frozen`, `field_names` lost |
| **Set / FrozenSet** | Collapse to `List`; upstream uses `$set`/`$frozenset` JSON tags but our C FFI bridge discards them |
| **Tuple vs List** | Both become Dart `List`; upstream uses `$tuple` JSON tag but our bridge discards it |
| **Bytes** | Upstream uses `$bytes` JSON tag; our bridge collapses to array of ints, no `Uint8List` mapping |
| **BigInt** | Serialized as number (if fits i64) or string; no automatic `BigInt` parsing in Dart |
| **Path** | Becomes plain string; `pathlib.Path` type information lost |
| **Repr / Cycle** | Non-serializable markers; likely cause JSON errors |

### 3.3 Missing Parameters & Options

| Gap | Detail |
|-----|--------|
| **script_name** | Cannot set `script_name` for `MontyRun::new`; defaults to internal name |
| **max_allocations** | `ResourceLimits::max_allocations` not configurable from Dart |
| **gc_interval** | `ResourceLimits::gc_interval` not configurable from Dart |
| **run_no_limits** | No fast path using `NoLimitTracker`; every execution pays tracking overhead |
| **Progress serialization** | `RunProgress::dump/load` and `ReplProgress::dump/load` enable suspend/resume of in-flight execution across process boundaries; not exposed |
| **set_max_duration** | `LimitedTracker::set_max_duration` for re-arming time limits between resume phases; not exposed |
| **check_large_result** | Preflight size check before returning large results; part of `ResourceTracker` trait; not exposed |
| **OS stat helpers** | `dir_stat`, `file_stat`, `symlink_stat`, `stat_result` — broader OS surface than just `getenv`/`environ`; not exposed |

---

## 4. Coverage Matrix

| Feature | Run API | REPL API | Async | OS | TypeCheck |
|---------|---------|----------|-------|-----|-----------|
| **Execute code** | YES | NO | NO | NO | NO |
| **External functions** | YES (positional only) | NO | NO | — | — |
| **Resume with value** | YES | NO | NO | — | — |
| **Resume with error** | YES | NO | NO | — | — |
| **Resume with future** | NO | NO | NO | — | — |
| **Snapshot/restore** | YES | NO | — | — | — |
| **Resource limits** | Partial (3 of 5) | NO | — | — | — |
| **Print output** | Batch only | NO | — | — | — |
| **Exception detail** | Partial (1 frame) | NO | — | — | — |
| **kwargs** | NO | NO | NO | — | — |
| **Native (FFI)** | YES | NO | NO | NO | NO |
| **Web (WASM/JS)** | YES | NO | NO | NO | NO |

Estimated coverage of upstream public API surface: **~25-35%**

The range depends on how heavily you weight the REPL and async surfaces.
dart_monty covers the Run API well (with gaps in kwargs, tracebacks, and
exception types) but omits entire REPL, async, OS, and type-checking
surfaces.

---

## 5. Prioritized Gaps for Future Work

### Tier 1 — High Value, Moderate Effort

These unlock the most important use cases and affect existing API quality.

1. **kwargs support** — Add `Map<String, Object?>? kwargs` to `MontyPending`.
   Requires: C FFI accessor for kwargs JSON, JS bridge accessor, platform
   interface model update.

2. **Full tracebacks** — Replace single-frame exception with
   `List<MontyStackFrame>`. Requires: JSON contract update in C FFI,
   new `MontyStackFrame` model, platform interface update.

3. **Exception types** — Add `String excType` field to `MontyException`
   (e.g. "ValueError", "TypeError"). Requires: C FFI accessor, JSON
   field addition.

4. **script_name parameter** — Add optional `scriptName` to `run()` and
   `start()`. Requires: C FFI update to pass through to `MontyRun::new`.

5. **Live print streaming** — Add optional `onPrint` callback to `run()`
   and `start()`. Native: `PrintWriter::Callback`. Web: message-based.

6. **call_id + method_call** — Expose `call_id: u32` and
   `method_call: bool` on `MontyPending`. Foundational for async
   futures (call_id correlation) and richer host-side dispatch.

### Tier 2 — New API Surface, Higher Effort

These add entirely new capabilities.

1. **REPL API** — `MontyRepl` class with `feed()`, session state
   persistence, snapshot/restore. Requires: New C FFI functions, new
   JS bridge class, new Dart `MontyRepl` class in platform interface.

2. **Async / Futures** — Support `ExternalResult::Future`,
   `FutureSnapshot`, `ResolveFutures`. Requires: New progress variant,
   new C FFI functions, cooperative resume protocol. Depends on
   call_id support (Tier 1 item 6).

3. **OS Calls** — Handle `RunProgress::OsCall` for `os.environ`,
   `os.getenv`, `stat`, `dir_stat`, `file_stat`, `symlink_stat`.
   Requires: New progress variant or automatic host-side resolution.

4. **Progress serialization** — Expose `RunProgress::dump/load` and
   `ReplProgress::dump/load` for suspending/resuming in-flight
   execution across process boundaries.

### Tier 3 — Nice to Have

1. **Type checking** — Expose static type checking (upstream JS:
   `Monty.typeCheck(prefixCode?)`, Rust: `monty-type-checking` crate).

2. **Rich MontyObject types** — Preserve `NamedTuple`, `Dataclass`,
   `Set`, `FrozenSet`, `Tuple`, `Bytes`, `Path` type identity through
   the JSON bridge using upstream `$tuple`/`$bytes`/`$set` tags.

3. **Resource limit completeness** — Expose `max_allocations`,
   `gc_interval`, and `set_max_duration` for re-arming between phases.

4. **run_no_limits fast path** — Skip tracker setup for unconstrained
   execution using `NoLimitTracker` (still enforces recursion depth 1000).
