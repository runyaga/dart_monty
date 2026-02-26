# State Persistence Across Executions

## Problem

Each `run()` or `start()` call creates a fresh `MontyRun` handle from compiled
code. When the call completes, the handle is freed. Variables defined in one
call are invisible to the next:

```dart
final monty = MontyNative(bindings: NativeIsolateBindingsImpl());
await monty.run('x = 42');      // handle created, x lives, handle freed
await monty.run('print(x)');    // new handle — NameError: x is not defined
```

This is by design at the Rust/C level, but consumers (soliplex's `execute_python`
tool) need state to persist across calls within a session — the LLM sets a
variable in one tool call and references it in the next.

## Spike Evidence

A spike (`test/integration/multi_instance_spike_test.dart`) confirmed:
- Multiple `MontyNative` instances run concurrently without GIL/FFI crashes
- `run()` does NOT persist state across calls (by design)
- State isolation between instances works correctly

## Why Not Use `inputs`?

The Rust API supports `input_names` + `inputs` on `MontyRun::new()` / `start()`,
but the C FFI layer (`monty_create`, `monty_start`) does NOT expose them. Both
`MontyNative` and `MontyWasm` call `rejectInputs()` which throws
`UnsupportedError` if inputs are non-empty:

```dart
// MontyStateMixin.rejectInputs():
'The $backendName backend does not support the inputs parameter. '
'Use externalFunctions with start()/resume() instead.'
```

Exposing inputs through the full stack (Rust C FFI → dart_monty_ffi →
dart_monty_native → dart_monty_wasm → platform_interface) is a large change
for a later milestone. The recommended workaround is already in the error
message: **use externalFunctions**.

## Design: `MontySession`

A new class in `dart_monty_platform_interface` that wraps any `MontyPlatform`
and adds cross-call state persistence using the existing external function
mechanism.

### Location

```
packages/dart_monty_platform_interface/
  lib/src/monty_session.dart          ← NEW
  test/monty_session_test.dart        ← NEW
```

Export from `dart_monty_platform_interface.dart` barrel.

### API

```dart
/// A stateful execution session that persists variables across calls.
///
/// Each [MontySession] wraps a [MontyPlatform] instance and maintains
/// a JSON-serialized snapshot of Python globals between executions.
/// Only JSON-serializable types persist (int, float, str, bool, list,
/// dict, None). Non-serializable values (classes, functions, modules)
/// are silently dropped after each call.
///
/// ```dart
/// final session = MontySession(platform: monty);
/// await session.run('x = 42');
/// final result = await session.run('x + 1');
/// print(result.value); // 43
/// ```
class MontySession {
  MontySession({required MontyPlatform platform});

  /// Execute [code] with state restored from previous calls.
  ///
  /// Returns the [MontyResult] from execution. Variables defined in
  /// [code] persist for subsequent calls (if JSON-serializable).
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  });

  /// Execute [code] iteratively (for external function dispatch).
  ///
  /// Same as [MontyPlatform.start] but with state restore/persist
  /// injected around [code].
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  });

  /// Clear all persisted state.
  void clearState();

  /// The current persisted state as a JSON-decoded map.
  ///
  /// Read-only snapshot. Returns empty map if no state persisted.
  Map<String, Object?> get state;

  /// Dispose the session. Does NOT dispose the underlying platform.
  void dispose();
}
```

### How It Works

Two internal host functions (`__restore_state__` and `__persist_state__`)
shuttle serialized state in/out of each execution, using the same
external-function mechanism as `__console_write__` in DefaultMontyBridge.

```
┌─────────────────────────────────────────────────────┐
│  Python execution (single start/resume cycle)       │
│                                                     │
│  1. __restore_state__() → bridge returns stored JSON│
│     → Python parses JSON, injects into globals()    │
│                                                     │
│  2. <user code runs>                                │
│     → external functions dispatched normally         │
│     → print() works normally                        │
│                                                     │
│  3. __persist_state__(json) → bridge stores JSON    │
│     → Python serializes globals, sends to bridge    │
└─────────────────────────────────────────────────────┘
```

### Code Wrapping

MontySession prepends a **restore preamble** and appends a **persist postamble**
to user code before passing it to `platform.start()`:

**Restore preamble** (runs before user code):
```python
__s = __restore_state__()
if __s and __s != '{}':
    import json as __j
    for __k, __v in __j.loads(__s).items():
        globals()[__k] = __v
    del __j, __k, __v
del __s
```

**Persist postamble** (runs after user code):
```python
import json as __j2
__state = {}
for __k2 in list(globals()):
    if not __k2.startswith('_'):
        __v2 = globals()[__k2]
        try:
            __j2.dumps(__v2)
            __state[__k2] = __v2
        except (TypeError, ValueError):
            pass
__persist_state__(__j2.dumps(__state))
del __j2, __state, __k2, __v2
```

All internal variables use `__dunder__` names so they don't collide with user
variables and are excluded from persistence (the `not __k2.startswith('_')` filter).

### Internal Start/Resume Loop

MontySession handles the start/resume loop, intercepting the two internal
functions while passing through all others:

```dart
Future<MontyResult> run(String code, {MontyLimits? limits, String? scriptName}) async {
  final wrappedCode = '$_restorePreamble\n$code\n$_persistPostamble';
  final allExtFns = [_restoreStateFn, _persistStateFn];

  var progress = await _platform.start(
    wrappedCode,
    externalFunctions: allExtFns,
    limits: limits,
    scriptName: scriptName,
  );

  while (true) {
    switch (progress) {
      case MontyPending(functionName: _restoreStateFn):
        progress = await _platform.resume(_stateJson);

      case MontyPending(functionName: _persistStateFn, arguments: [final json]):
        _stateJson = json.toString();
        progress = await _platform.resume(null);

      case MontyComplete(:final result):
        return result;

      case MontyPending():
        // Unexpected external function in run() mode.
        // For start() mode, this is returned to the caller.
        progress = await _platform.resumeWithError(
          'Unexpected external function in run() mode',
        );

      case MontyResolveFutures():
        progress = await _platform.resume(null);
    }
  }
}
```

For `start()`, MontySession handles `__restore_state__` and `__persist_state__`
internally but returns other `MontyPending` values to the caller. The caller
resumes via `_platform.resume()` directly. The session intercepts the persist
call when execution finally completes.

### What Persists

| Python type | Persists | JSON type |
|-------------|----------|-----------|
| `int` | Yes | number |
| `float` | Yes | number |
| `str` | Yes | string |
| `bool` | Yes | boolean |
| `None` | Yes | null |
| `list` (of primitives) | Yes | array |
| `dict` (str keys, primitive values) | Yes | object |
| Nested list/dict | Yes | nested |
| Custom classes | No | — |
| Functions, lambdas | No | — |
| Modules | No (re-import) | — |
| File handles | No | — |
| `set`, `tuple` | No (not JSON) | — |

### Error Handling

- If user code **raises an exception**, the persist postamble never runs.
  State from the previous successful call is preserved (no partial corruption).
- If the restore preamble fails (corrupted JSON), the error propagates as a
  `MontyException`. Call `clearState()` to reset.
- If `__persist_state__` receives invalid JSON, the old state is preserved.

### Platform Compatibility

| Platform | Works? | Notes |
|----------|--------|-------|
| Native (macOS, Linux) | Yes | Uses `NativeIsolateBindingsImpl` per instance |
| Web (WASM) | Yes | Uses `WasmBindingsJs` per instance |
| iOS, Android, Windows | Yes | Same as native (when platform supported) |

The implementation sits in `dart_monty_platform_interface` — pure Dart, no
platform-specific code. It wraps any `MontyPlatform` implementation.

## Tests

### Unit tests (`test/monty_session_test.dart`)

Use `MockMontyPlatform` that enqueues `MontyPending`/`MontyComplete` responses:

```
1. "set and read variable"
   - run('x = 42') → completes
   - run('x + 1') → verify restore preamble sent stored state
   - result.value == 43

2. "multiple types persist"
   - run('a = 1; b = "hello"; c = [1,2]; d = {"k": "v"}; e = True; f = None')
   - Verify persisted JSON contains all 6 variables with correct types

3. "non-serializable silently dropped"
   - run('import math; x = 42')
   - Verify state contains x=42 but not math

4. "error preserves previous state"
   - run('x = 10') → succeeds, state has x=10
   - run('1/0') → ZeroDivisionError, persist postamble never runs
   - run('x') → state still has x=10

5. "clearState resets"
   - run('x = 1')
   - clearState()
   - run('x') → NameError

6. "state isolated between sessions"
   - sessionA.run('x = 1')
   - sessionB.run('x') → NameError

7. "works with external functions (start mode)"
   - start('result = fetch("url")') with externalFunctions: ['fetch']
   - Verify __restore_state__ handled internally
   - Verify fetch() MontyPending returned to caller
   - After completion, verify __persist_state__ handled internally

8. "dunder variables excluded from state"
   - run('__private = 1; _also_private = 2; public = 3')
   - Verify only 'public' in state

9. "empty state on first run"
   - First run sends '{}' to __restore_state__
   - Preamble handles empty state gracefully

10. "large state round-trip"
    - run() with 100 variables
    - Verify all persist and restore correctly
```

### Integration tests (tagged `integration`, requires native library)

New file: `packages/dart_monty_native/test/integration/session_test.dart`

```
1. "real state persistence across calls"
   - session.run('x = 42')
   - result = session.run('x + 1')
   - expect result.value == 43

2. "real multi-type persistence"
   - session.run('nums = [1,2,3]; name = "test"; flag = True')
   - result = session.run('[nums, name, flag]')
   - expect result.value == [[1,2,3], "test", true]

3. "real error recovery"
   - session.run('x = 10')
   - session.run('1/0') → error
   - result = session.run('x')
   - expect result.value == 10

4. "real session isolation"
   - sessionA.run('x = 1')
   - sessionB.run('x') → NameError

5. "concurrent sessions"
   - Future.wait([sessionA.run('x = 1'), sessionB.run('x = 2')])
   - resultA = sessionA.run('x'), resultB = sessionB.run('x')
   - expect resultA.value == 1, resultB.value == 2
```

Run with:
```bash
# Native
cd packages/dart_monty_native
dart test --run-skipped test/integration/session_test.dart

# Unit (all platforms)
cd packages/dart_monty_platform_interface
dart test test/monty_session_test.dart
```

## Future: Expose `inputs` via C FFI

For a cleaner long-term solution, expose the Rust API's `input_names` and
`inputs` parameters through the full stack:

1. **`native/src/lib.rs`**: Add `input_names_json` param to `monty_create()`,
   `inputs_json` param to `monty_start()` and `monty_run()`
2. **`dart_monty_ffi`**: Update `NativeBindings`, `NativeBindingsFfi`,
   `FfiCoreBindings`
3. **`dart_monty_native`**: Update `NativeIsolateBindings`,
   `NativeIsolateBindingsImpl`, `MontyNative`
4. **`dart_monty_wasm`**: Update `WasmBindings`, `WasmBindingsJs`, JS bridge
5. **`dart_monty_platform_interface`**: Update `MontyPlatform`, remove
   `rejectInputs()`

This enables passing `MontyObject` inputs directly (not just JSON-serializable
types) and removes the code-wrapping overhead. But it's a cross-cutting change
across all 5 packages + the Rust C FFI.

## Files Summary

| File | Action |
|------|--------|
| `packages/dart_monty_platform_interface/lib/src/monty_session.dart` | NEW |
| `packages/dart_monty_platform_interface/lib/dart_monty_platform_interface.dart` | MODIFY (add export) |
| `packages/dart_monty_platform_interface/test/monty_session_test.dart` | NEW |
| `packages/dart_monty_native/test/integration/session_test.dart` | NEW |
