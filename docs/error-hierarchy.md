# Error Hierarchy and Control Flow

## Sealed Error Hierarchy

All interpreter errors flow through the sealed `MontyError` hierarchy.
Consumers use exhaustive pattern matching:

```dart
try {
  await platform.run(code);
} on MontyError catch (e) {
  switch (e) {
    case MontyScriptError(:final exception):
      // Python exception — e.message, e.excType, e.exception (full details)
    case MontyPanicError():
      // Rust panic — interpreter bug, harsh backoff
    case MontyCrashError():
      // Isolate/Worker died — restart immediately
    case MontyDisposedError():
      // Disposed while running — fix the caller
    case MontyResourceError():
      // OOM, timeout, WASM trap — reduce limits, retry
  }
}
```

## Type Relationships

```text
Exception (dart:core)
  ├── MontyError (sealed)           ← thrown by platform on failure
  │     ├── MontyScriptError        ← Python exceptions (wraps MontyException)
  │     ├── MontyPanicError         ← Rust catch_unwind
  │     ├── MontyCrashError         ← Isolate/Worker death
  │     ├── MontyDisposedError      ← disposed during execution
  │     └── MontyResourceError      ← MemoryLimitExceeded, timeout, WASM trap
  │
  └── MontyException (standalone)   ← data class for Python exception details
        fields: message, excType, filename, lineNumber, columnNumber,
                sourceCode, traceback: List<MontyStackFrame>
```

`MontyScriptError.exception` carries the full `MontyException` with
traceback, source location, and Python exception type. The `message` and
`excType` fields are duplicated on `MontyScriptError` for convenience.

## Error Source to Sealed Type Mapping

| Source | excType | Sealed type thrown |
|--------|---------|-------------------|
| Python `raise ValueError(...)` | `ValueError` | `MontyScriptError` |
| Python `1/0` | `ZeroDivisionError` | `MontyScriptError` |
| Python syntax error | `SyntaxError` | `MontyScriptError` |
| Any Python exception | `*` (except below) | `MontyScriptError` |
| Memory limit exceeded | `MemoryLimitExceeded` | `MontyResourceError` |
| Timeout exceeded | `TimeoutError` | `MontyResourceError` |
| WASM trap (stack overflow) | `WasmTrap` | `MontyResourceError` |
| Rust panic (catch_unwind) | -- | `MontyPanicError` |
| Isolate/Worker unexpected exit | -- | `MontyCrashError` |
| Disposed during execution | -- | `MontyDisposedError` |
| Calling run() while active | -- | `StateError` (not MontyError) |

## Control Flow Through Boundaries

```text
Python raises ZeroDivisionError
  │
  ▼
Rust monty crate catches → RunProgress::Error { exception JSON }
  │
  ▼ (FFI path)                           ▼ (WASM path)
NativeBindingsFfi reads                  Worker postMessage
  error JSON from C out-param              { ok: false, error, excType,
  │                                          filename, lineNumber, ... }
  ▼                                        │
FfiCoreBindings._translateError            ▼
  → CoreProgressResult(state:'error')    WasmCoreBindings._translateProgressResult
  │                                        → CoreProgressResult(state:'error')
  ▼                                        │
BaseMontyPlatform.translateProgress        ▼
  │                                      BaseMontyPlatform.translateProgress
  ▼                                        │
_throwError(message, excType, ...)         ▼
  │                                      _throwError(message, excType, ...)
  ├─ excType == 'MemoryLimitExceeded'      │
  │   → throw MontyResourceError           ├─ (same mapping)
  │                                        │
  └─ all other excTypes                    └─ all other excTypes
      → build MontyException(...)              → build MontyException(...)
      → throw MontyScriptError(                → throw MontyScriptError(
          message, excType, exception)             message, excType, exception)
```

## Propagation Through Isolate Boundary

```text
Background Isolate catches during execution:
  │
  ├─ on MontyScriptError → _ErrorResponse(id, error)
  │                          main thread rethrows as MontyScriptError
  │
  ├─ on MontyError → _MontyErrorResponse(id, error)
  │                    main thread rethrows the sealed subtype
  │
  └─ on Object → _GenericErrorResponse(id, message)
                   main thread throws StateError(message)

Isolate exits unexpectedly:
  → _failAllPending('Isolate exited')
    → all pending completers receive StateError
```

## Propagation Through Bridge

```text
MontyBridge (DefaultMontyBridge._run) catches:
  │
  ├─ on MontyScriptError catch (e)
  │   → log warning
  │   → flush print buffer → emit BridgeTextStart/Content/End
  │   → emit BridgeRunError(
  │       message: e.exception!.message,
  │       exception: e.exception,
  │       printOutput: buffered output)
  │
  ├─ on MontyError catch (e)
  │   → log warning
  │   → emit BridgeRunError(message: e.message)
  │
  └─ on Object catch (e, st)
      → log error with stack trace
      → emit BridgeRunError(message: '$e')
```

## MontyResult.error vs Thrown Errors

A successful `run()` returns `MontyResult` which may carry a non-fatal
`MontyException` in its `error` field (e.g., a `SyntaxWarning` that didn't
prevent execution). A failed `run()` **throws** a sealed `MontyError` --
it never returns a `MontyResult`.

```text
platform.run(code)
  │
  ├─ ok: true  → return MontyResult(value: ..., error: MontyException?)
  │              (error may be non-null for warnings)
  │
  └─ ok: false → throw MontyScriptError / MontyResourceError
                  (never returns a MontyResult)
```

## Resource Safety: NativeFinalizer

`FfiCoreBindings` attaches a `NativeFinalizer` backed by `monty_free()` to
every active Rust handle. If a `MontyFfi` instance is garbage collected
without `dispose()`, the finalizer automatically frees the handle, preventing
a permanent native memory leak. The finalizer is detached on explicit
`_freeHandle()` or `dispose()` calls to avoid double-free.
