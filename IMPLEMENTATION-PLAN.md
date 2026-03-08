# Issue #92: Efficient WASM Execution — Implementation Plan

## Overview

Strip unnecessary NAPI-RS overhead (256MB memory, 4 idle Workers, COOP/COEP requirement)
from dart_monty's WASM path, then build a multi-session Worker pool architecture.

**Review gate (gemini-3.1-pro) identified and corrected 3 fatal flaws in v1:**
1. NAPI-RS top-level module execution prevents passing pre-compiled WebAssembly.Module
2. MontySnapshot.dump() may return a view into WASM memory — transferring buffer detaches it
3. Dart factory constructors cannot be async — sessionId must live in WasmCoreBindings

---

## EXP-W1: Gate Experiment

**All architecture decisions depend on this experiment.**

### Patch Target

The bundled `dart_monty_worker.js` contains the NAPI-RS browser loader from
`@pydantic/monty-wasm32-wasi/monty.wasi-browser.js` which configures:

```javascript
// monty.wasi-browser.js lines 18-22
const __sharedMemory = new WebAssembly.Memory({
  initial: 4000,    // 256MB
  maximum: 65536,   // 4GB
  shared: true,     // requires SharedArrayBuffer + COOP/COEP
})

// monty.wasi-browser.js line 32
asyncWorkPoolSize: 4,   // spawns 4 idle Workers for Rust async
```

### Patch Implementation

Add post-esbuild patching in `packages/dart_monty_wasm/js/build.js` after
the worker bundle step (after line 30), BEFORE the existing bare specifier patch:

```javascript
// Patch NAPI-RS config: strip SharedArrayBuffer + async pool
workerSrc = workerSrc.replace(
  /new WebAssembly\.Memory\({[\s\n\r]*initial: 4000,[\s\n\r]*maximum: 65536,[\s\n\r]*shared: true,?[\s\n\r]*}\)/g,
  'new WebAssembly.Memory({ initial: 256, maximum: 65536, shared: false })'
);
workerSrc = workerSrc.replace(
  /asyncWorkPoolSize: 4/g,
  'asyncWorkPoolSize: 0'
);
```

Note: esbuild is invoked WITHOUT `--minify`, so the NAPI-RS source formatting
is preserved in the bundle. The regex matches the esbuild output reliably.

### Success Criteria

1. Run `bash tool/test_python_ladder.sh` — all tiers pass
2. Run `bash tool/test_cross_path_parity.sh` — JSONL diff clean
3. No `memory import must be a SharedArrayBuffer` error

### Failure Pivot

If atomics error occurs: WASM binary compiled with `+atomics`. Pivot to Phase 3
(bypass NAPI-RS entirely with direct wasm32-wasi compilation).

### Rollback

Remove the patching lines from `build.js`, re-run build. Original behavior restored.

---

## Phase 1: Strip NAPI-RS Overhead

Formalize EXP-W1 into a permanent build change.

### Files Changed

| File | Change |
|------|--------|
| `packages/dart_monty_wasm/js/build.js` | Add post-esbuild patching (memory + async pool) |

### Verification

1. `bash tool/test_python_ladder.sh` — all tiers pass
2. `bash tool/test_cross_path_parity.sh` — parity clean
3. Dart unit tests: `dart test` in `packages/dart_monty_wasm/`
4. Manual browser test: verify 1 Worker (not 5), ~16MB initial memory
5. Verify page loads WITHOUT COOP/COEP headers

### wasi-worker-browser.mjs

Does NOT need patching. Setting `asyncWorkPoolSize: 0` prevents the
sub-workers from ever being created. The file is still copied to assets
for compatibility but is never loaded at runtime.

---

## Phase 2: Multi-Session Worker Pool

Replace singleton worker with session-mapped pool.

### Architecture (Corrected)

```
Dart (MontyWasm)     WasmCoreBindings      JS Bridge           Workers
┌──────────────┐     ┌──────────────┐      ┌────────────┐      ┌──────────┐
│ MontyWasm A   │────│ _sessionId A │─────│ sessions    │─────│ Worker A │
│ MontyWasm B   │────│ _sessionId B │─────│ Map         │─────│ Worker B │
└──────────────┘     └──────────────┘      └────────────┘      └──────────┘
                     (async init creates                (each Worker imports
                      session, stores ID)                monty.wasi-browser.js
                                                         independently; browser
                                                         HTTP-caches the .wasm)
```

**Key design correction:** Each Worker does its own `import` of
`monty.wasi-browser.js`, which triggers its own `fetch()` of the .wasm binary.
The browser's HTTP cache ensures the .wasm is only downloaded once. We do NOT
pass a pre-compiled `WebAssembly.Module` via `postMessage` because NAPI-RS's
top-level module execution prevents accepting an external module.

### bridge.js Changes

**Global state:**
```javascript
// Before (singleton)
let worker = null;
let nextId = 1;
const pending = new Map();

// After (multi-session)
let nextSessionId = 1;
const sessions = new Map(); // sessionId -> { worker, nextMsgId, pending }
```

**New functions:**
- `createSession()` — create Worker, wait for `ready` message, return sessionId
- `disposeSession(sessionId)` — `worker.terminate()`, reject pending, remove from map

**Modified functions:**
- `init()` — becomes no-op or removed (initialization happens per-session in createSession)
- `run(sessionId, code, limitsJson, scriptName)` — route to correct worker
- `start(sessionId, code, extFnsJson, limitsJson, scriptName)` — same
- `resume(sessionId, valueJson)` — same
- `resumeWithError(sessionId, errorJson)` — same
- `snapshot(sessionId)` — same
- `restore(sessionId, dataBase64)` — same
- `discover()` — returns `{ sessionCount, architecture: 'worker-pool' }`
- `dispose(sessionId)` — alias for disposeSession

**Hard timeout (defense in depth):**
```javascript
function callWorker(sessionId, msg, timeoutMs) {
  return new Promise((resolve, reject) => {
    const session = sessions.get(sessionId);
    const msgId = session.nextMsgId++;
    session.pending.set(msgId, { resolve, reject });

    const timer = setTimeout(() => {
      session.worker.terminate();
      sessions.delete(sessionId);
      reject(new Error('Execution timed out'));
    }, timeoutMs);

    // On response: clearTimeout(timer), resolve
    worker.postMessage({ ...msg, id: msgId });
  });
}
```

### worker_src.js Changes

**No change to import strategy.** The static top-level `import` of
`monty.wasi-browser.js` stays. Each Worker independently loads the NAPI-RS
module (browser caches the .wasm fetch). This is simpler and more robust
than trying to inject a pre-compiled module.

The worker code remains as-is for Phase 2a. The only change is that
the bridge now creates multiple Workers instead of one.

### Dart Side Changes (Corrected Architecture)

**Key correction:** `sessionId` lives in `WasmCoreBindings`, NOT in `MontyWasm`.
The `MontyWasm` factory constructor is synchronous and cannot call async
`createSession()`. Instead, `WasmCoreBindings.init()` (which is already async)
creates the session.

**WasmBindings (abstract interface):**
- Add: `Future<int> createSession()`
- Add: `Future<void> disposeSession(int sessionId)`
- All methods gain `int sessionId` parameter

**WasmBindingsJs (JS interop implementation):**
- New JS interop: `DartMontyBridge.createSession`, `DartMontyBridge.disposeSession`
- All `_js*` functions gain `JSNumber sessionId` parameter

**WasmCoreBindings (adapter — owns session lifecycle):**
```dart
class WasmCoreBindings implements MontyCoreBindings {
  int? _sessionId;

  @override
  Future<bool> init() async {
    if (_sessionId != null) return true;
    _sessionId = await _bindings.createSession();
    return true;
  }

  @override
  Future<CoreRunResult> run(String code, ...) async {
    // passes _sessionId! to _bindings.run(_sessionId!, code, ...)
  }

  @override
  Future<void> dispose() async {
    if (_sessionId != null) {
      await _bindings.disposeSession(_sessionId!);
      _sessionId = null;
    }
  }
}
```

**MontyWasm (public API):**
- No change needed. The factory constructor stays synchronous.
- `init()` is called by `BaseMontyPlatform` before first use, which
  triggers `WasmCoreBindings.init()` → `createSession()`.

**MockWasmBindings (test mock):**
- Must be updated to implement new `createSession()` / `disposeSession()` methods
- Must accept `sessionId` on all method signatures

### Snapshot Transfer (Corrected)

**NOT zero-copy.** `MontySnapshot.dump()` may return a `Uint8Array` view
into WASM linear memory. Marking the underlying `.buffer` as Transferable
would detach the WASM memory and crash the instance.

Instead: **explicit copy** to a new `ArrayBuffer`:
```javascript
function handleSnapshot(id) {
  const bytes = activeSnapshot.dump();
  // MUST copy — bytes may be a view into WASM memory
  const copy = new Uint8Array(bytes).buffer.slice(0);
  self.postMessage({ type: 'result', id, ok: true, data: copy }, [copy]);
}
```

This is still dramatically faster than Base64 encoding (avoids the 33%
size expansion and string allocation overhead).

### Message Protocol

```
Dart → JS Bridge: { sessionId, method, ...args }
JS Bridge → Worker: { type, id, ...args }  (unchanged per-worker)
Worker → JS Bridge: { type, id, ...result } (unchanged, routed by session)
```

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| WASM binary requires atomics | Blocks Phase 1 entirely | Pivot to Phase 3 (direct wasm32-wasi) |
| Worker spawn latency (~200-500ms) | Slow session creation | Pre-warm pool; browser caches .wasm |
| Browser inconsistencies | terminate/compileStreaming | Test Chrome, Firefox, Safari |
| Timer precision without COOP/COEP | ~100μs clamping | Document; hard timeout backstop |
| Breaking WasmBindings API | All consumers + mocks must update | Single atomic commit |
| esbuild output format changes | Regex patch breaks | CI test catches; regex is conservative |

---

## Implementation Order

1. **EXP-W1** — Patch build.js, rebuild assets, run tests (GATE)
2. **Phase 1** — If EXP-W1 passes, formalize patch, commit
3. **Phase 2a** — Multi-session bridge.js (JS only, Dart singleton still works)
4. **Phase 2b** — Dart API changes (WasmBindings → WasmBindingsJs → WasmCoreBindings)
5. **Phase 2c** — Update MontyWasm + tests + mocks
6. **Phase 2d** — Hard timeout + supervision
7. **Phase 2e** — Snapshot copy-transfer (replace Base64)

---

## File Change Manifest

### Phase 1
| File | Change |
|------|--------|
| `packages/dart_monty_wasm/js/build.js` | Post-esbuild regex patch for memory + async pool |

### Phase 2
| File | Change |
|------|--------|
| `packages/dart_monty_wasm/js/src/bridge.js` | Singleton → sessions Map, createSession/disposeSession, hard timeout |
| `packages/dart_monty_wasm/js/src/worker_src.js` | Snapshot copy-transfer (Phase 2e only) |
| `packages/dart_monty_wasm/js/build.js` | Rebuild assets after JS changes |
| `packages/dart_monty_wasm/lib/src/wasm_bindings.dart` | Add sessionId to all methods, add create/disposeSession |
| `packages/dart_monty_wasm/lib/src/wasm_bindings_js.dart` | JS interop for new bridge functions, sessionId params |
| `packages/dart_monty_wasm/lib/src/wasm_core_bindings.dart` | Own _sessionId, create in init(), pass through all calls |
| `packages/dart_monty_wasm/lib/src/monty_wasm.dart` | No changes (session managed by WasmCoreBindings) |
| `packages/dart_monty_wasm/test/mock_wasm_bindings.dart` | Update mock for new API |
| `packages/dart_monty_wasm/test/monty_wasm_test.dart` | Update tests for session-aware API |
| `packages/dart_monty_wasm/test/wasm_core_bindings_test.dart` | Update tests for session lifecycle |
