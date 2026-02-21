# Monty Rust API Reference

Pinned rev: `87f8f31` (2025 — `pyo3-build-config` for ubuntu tests)

Source: `https://github.com/pydantic/monty.git`

## Entry Point: `MontyRun`

```rust
pub struct MontyRun { /* private */ }

impl MontyRun {
    pub fn new(
        code: String,
        script_name: &str,
        input_names: Vec<String>,
        external_functions: Vec<String>,
    ) -> Result<Self, MontyException>

    pub fn code(&self) -> &str

    pub fn run(
        &self,
        inputs: Vec<MontyObject>,
        resource_tracker: impl ResourceTracker,
        print: &mut PrintWriter<'_>,
    ) -> Result<MontyObject, MontyException>

    pub fn run_no_limits(
        &self,
        inputs: Vec<MontyObject>,
    ) -> Result<MontyObject, MontyException>

    pub fn start<T: ResourceTracker>(
        self,                          // NOTE: consumes self
        inputs: Vec<MontyObject>,
        resource_tracker: T,
        print: &mut PrintWriter<'_>,
    ) -> Result<RunProgress<T>, MontyException>

    pub fn dump(&self) -> Result<Vec<u8>, postcard::Error>
    pub fn load(bytes: &[u8]) -> Result<Self, postcard::Error>
}
```

## Execution Progress: `RunProgress<T>`

```rust
pub enum RunProgress<T: ResourceTracker> {
    FunctionCall {
        function_name: String,
        args: Vec<MontyObject>,
        kwargs: Vec<(MontyObject, MontyObject)>,
        call_id: u32,
        method_call: bool,
        state: Snapshot<T>,
    },
    OsCall {
        function: OsFunction,
        args: Vec<MontyObject>,
        kwargs: Vec<(MontyObject, MontyObject)>,
        call_id: u32,
        state: Snapshot<T>,
    },
    ResolveFutures(FutureSnapshot<T>),
    Complete(MontyObject),
}
```

## Resuming: `Snapshot<T>`

```rust
pub struct Snapshot<T: ResourceTracker> { /* private */ }

impl<T: ResourceTracker> Snapshot<T> {
    pub fn run(
        self,
        result: impl Into<ExternalResult>,
        print: &mut PrintWriter<'_>,
    ) -> Result<RunProgress<T>, MontyException>

    pub fn run_pending(
        self,
        print: &mut PrintWriter<'_>,
    ) -> Result<RunProgress<T>, MontyException>

    pub fn tracker_mut(&mut self) -> &mut T
}
```

## External Results

```rust
pub enum ExternalResult {
    Return(MontyObject),
    Error(MontyException),
    Future,
}

impl From<MontyObject> for ExternalResult { /* ... */ }
impl From<MontyException> for ExternalResult { /* ... */ }
```

## Python Values: `MontyObject`

```rust
pub enum MontyObject {
    Ellipsis,
    None,
    Bool(bool),
    Int(i64),
    BigInt(BigInt),     // num-bigint
    Float(f64),
    String(String),
    Bytes(Vec<u8>),
    List(Vec<Self>),
    Tuple(Vec<Self>),
    NamedTuple { type_name: String, field_names: Vec<String>, values: Vec<Self> },
    Dict(DictPairs),
    Set(Vec<Self>),
    FrozenSet(Vec<Self>),
    Path(String),
    Dataclass { name: String, type_id: u64, field_names: Vec<String>, attrs: DictPairs, frozen: bool },
    Type(Type),
    BuiltinFunction(BuiltinsFunctions),
    Exception { exc_type: ExcType, arg: Option<String> },
    Repr(String),
    Cycle(HeapId, String),
}

pub struct DictPairs(Vec<(MontyObject, MontyObject)>);
```

## Exceptions: `MontyException`

```rust
pub struct MontyException { /* private */ }

impl MontyException {
    pub fn new(exc_type: ExcType, message: Option<String>) -> Self
    pub fn exc_type(&self) -> ExcType
    pub fn message(&self) -> Option<&str>
    pub fn into_message(self) -> Option<String>
    pub fn traceback(&self) -> &[StackFrame]
    pub fn summary(&self) -> String     // "Type: message"
    pub fn py_repr(&self) -> String     // "Type('message')"
}

pub struct StackFrame {
    pub filename: String,
    pub start: CodeLoc,
    pub end: CodeLoc,
    pub frame_name: Option<String>,
    pub preview_line: Option<String>,
    pub hide_caret: bool,
    pub hide_frame_name: bool,
}

pub struct CodeLoc {
    pub line: u16,      // 1-based
    pub column: u16,    // 1-based
}
```

## Resource Limits

```rust
pub trait ResourceTracker: fmt::Debug {
    fn on_allocate(&mut self, get_size: impl FnOnce() -> usize) -> Result<(), ResourceError>;
    fn on_free(&mut self, get_size: impl FnOnce() -> usize);
    fn check_time(&self) -> Result<(), ResourceError>;
    fn check_recursion_depth(&self, depth: usize) -> Result<(), ResourceError>;
    fn check_large_result(&self, estimated_bytes: usize) -> Result<(), ResourceError>;
}

pub struct NoLimitTracker;   // implements ResourceTracker (no-op)

pub struct LimitedTracker { /* private */ }

impl LimitedTracker {
    pub fn new(limits: ResourceLimits) -> Self
    pub fn allocation_count(&self) -> usize
    pub fn current_memory(&self) -> usize
    pub fn elapsed(&self) -> Duration
    pub fn set_max_duration(&mut self, duration: Duration)
}

pub struct ResourceLimits {
    pub max_allocations: Option<usize>,
    pub max_duration: Option<Duration>,
    pub max_memory: Option<usize>,
    pub gc_interval: Option<usize>,
    pub max_recursion_depth: Option<usize>,
}

impl ResourceLimits {
    pub fn new() -> Self   // sets max_recursion_depth: 1000
    pub fn max_allocations(self, limit: usize) -> Self
    pub fn max_duration(self, limit: Duration) -> Self
    pub fn max_memory(self, limit: usize) -> Self
    pub fn max_recursion_depth(self, limit: Option<usize>) -> Self
}
```

## Print Output

```rust
pub enum PrintWriter<'a> {
    Disabled,
    Stdout,
    Collect(String),
    Callback(&'a mut dyn PrintWriterCallback),
}

impl PrintWriter<'_> {
    pub fn stdout_write(&mut self, output: Cow<'_, str>) -> Result<(), MontyException>
    pub fn collected_output(&self) -> Option<&str>
}
```

## JSON Contract (C FFI to Dart)

All JSON must match Dart `fromJson` factories exactly (snake\_case keys):

| Dart type | JSON shape |
|-----------|-----------|
| `MontyResult` | `{ "value": ..., "error": {...}?, "usage": {...} }` |
| `MontyException` | `{ "message": "...", "filename": "..."?, "line_number": N?, "column_number": N?, "source_code": "..."? }` |
| `MontyResourceUsage` | `{ "memory_bytes_used": N, "time_elapsed_ms": N, "stack_depth_used": N }` |
| `MontyProgress` | discriminated by `"type": "complete"` or `"pending"` |
| `MontyComplete` | `{ "type": "complete", "result": { MontyResult } }` |
| `MontyPending` | `{ "type": "pending", "function_name": "...", "arguments": [...] }` |

## MontyObject to JSON Mapping

| MontyObject variant | JSON |
|--------------------|------|
| `None` | `null` |
| `Bool(b)` | `true` / `false` |
| `Int(n)` | number |
| `BigInt(n)` | number if fits i64, else string |
| `Float(f)` | number |
| `String(s)` | string |
| `List(v)` / `Tuple(v)` | array |
| `Dict(pairs)` | object (string keys) or array of pairs |
| `Ellipsis` | `"..."` |
| `Bytes(v)` | base64 string or array of ints |
| `Set(v)` / `FrozenSet(v)` | array |
