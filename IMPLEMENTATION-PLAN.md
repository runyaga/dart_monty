# Issue #92: Efficient WASM Execution — Implementation Plan

## Overview

Strip unnecessary NAPI-RS overhead (256MB memory, 4 idle Workers, COOP/COEP requirement)
from dart_monty's WASM path, then build a multi-session Worker pool architecture.

**Review gates (gemini-3.1-pro) identified and corrected fatal flaws across two rounds:**

### Round 1 (pre-implementation) — 3 fatal flaws in v1 plan:
1. NAPI-RS top-level module execution prevents passing pre-compiled WebAssembly.Module
2. MontySnapshot.dump() may return a view into WASM memory — transferring buffer detaches it
3. Dart factory constructors cannot be async — sessionId must live in WasmCoreBindings

### Round 2 (post-Phase 1 merge) — 3 fatal flaws in Phase 2 plan:
4. Snapshot `JSON.stringify(ArrayBuffer)` → `{}` — must bypass JSON serialization
5. Orphaned promises on timeout — must reject ALL pending, not just current message
6. `MontyWasm.restore` skips `init()` — `_sessionId` will be null

---

## EXP-W1: Gate Experiment — COMPLETED

**All architecture decisions depend on this experiment.** PASSED.

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

### Results

| Change | Result |
|--------|--------|
| `shared: false` | FAILS — LinkError: "mismatch in shared state of memory" |
| `initial: 256` (16MB) | FAILS — LinkError: minimum 1009 pages required |
| `initial: 1024` (64MB) | PASSES — all ladder tests green |
| `asyncWorkPoolSize: 0` | PASSES — Monty is synchronous C-ABI only |

### Key Finding

`shared: true` MUST stay — the WASM binary was compiled with `--shared-memory`.
This means COOP/COEP headers are still required. Removing them requires Phase 3
(upstream recompilation without `+atomics`).

---

## Phase 1: Strip NAPI-RS Overhead — MERGED (PR #94)

Formalized EXP-W1 into a permanent build change.

### What Was Shipped

Post-esbuild regex patching in `packages/dart_monty_wasm/js/build.js`:
- `initial: 4000|4e3` → `initial: 1024` (256MB → 64MB, 4x reduction)
- `asyncWorkPoolSize: 4` → `asyncWorkPoolSize: 0` (5 Workers → 1)
- Build-time assertion: `workerSrc === workerSrcBeforePatch` + `includes()` checks
- Memory growth test fixture: `tier_16_memory_growth.json` (3 tests, >64MB allocations)

### Phase 1 Constraints (from architect review)

1. **COOP/COEP still required** — `shared: true` means `SharedArrayBuffer` is in use.
   Deployments MUST serve with `Cross-Origin-Opener-Policy: same-origin` and
   `Cross-Origin-Embedder-Policy: require-corp`. Cannot be lifted until Phase 3.
2. **Regex is brittle** — relies on `--no-minify` esbuild output. Build assertion
   is the safety net. If upstream NAPI-RS changes defaults (different page count,
   pool size), regex silently fails but assertion catches it.
3. **esbuild `--minify` would break** — never add `--minify` to the worker bundle
   step without updating the regex patterns.

### wasi-worker-browser.mjs

Does NOT need patching. Setting `asyncWorkPoolSize: 0` prevents the
sub-workers from ever being created. The file is still copied to assets
for compatibility but is never loaded at runtime.

---

## Phase 2: Multi-Session Worker Pool

Replace singleton worker with session-mapped pool.

### Architecture

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

**Key design constraint:** Each Worker does its own `import` of
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
const sessions = new Map(); // sessionId -> { worker, nextMsgId, pending, timeoutMs }
```

**New functions:**
- `createSession()` — create Worker, attach `onerror` handler, wait for `ready`, return sessionId
- `disposeSession(sessionId)` — clear all pending timers, reject all pending, `worker.terminate()`, remove from map

**Modified functions:**
- `init()` — becomes no-op or removed (initialization happens per-session in createSession)
- `run(sessionId, code, limitsJson, scriptName)` — route to correct worker
- `start(sessionId, code, extFnsJson, limitsJson, scriptName)` — same, cache timeoutMs on session
- `resume(sessionId, valueJson)` — same, use cached timeoutMs from session
- `resumeWithError(sessionId, errorJson)` — same
- `snapshot(sessionId)` — returns raw JS object (NOT JSON string), see Snapshot Transfer below
- `restore(sessionId, dataBase64)` — same
- `discover()` — returns `{ sessionCount, architecture: 'worker-pool' }`
- `dispose(sessionId)` — alias for disposeSession

**Hard timeout (corrected — stores timer, clears on response, rejects ALL pending):**
```javascript
function callWorker(sessionId, msg, timeoutMs) {
  return new Promise((resolve, reject) => {
    const session = sessions.get(sessionId);
    if (!session) {
      reject(new Error(`Session ${sessionId} not found`));
      return;
    }
    const msgId = session.nextMsgId++;

    const timer = setTimeout(() => {
      // Reject ALL pending promises for this session, not just this one
      for (const req of session.pending.values()) {
        clearTimeout(req.timer);
        req.reject(new Error('Execution timed out'));
      }
      session.pending.clear();
      session.worker.terminate();
      sessions.delete(sessionId);
    }, timeoutMs);

    session.pending.set(msgId, { resolve, reject, timer });
    session.worker.postMessage({ ...msg, id: msgId });
  });
}
```

**Worker `onerror` handler (crash recovery):**
```javascript
function createSession() {
  return new Promise((resolve, reject) => {
    const sessionId = nextSessionId++;
    const worker = new Worker(workerUrl, { type: 'module' });

    worker.onerror = (event) => {
      const session = sessions.get(sessionId);
      if (session) {
        // Reject all pending promises — worker is dead
        for (const req of session.pending.values()) {
          clearTimeout(req.timer);
          req.reject(new Error(`Worker crashed: ${event.message}`));
        }
        session.pending.clear();
        sessions.delete(sessionId);
      }
    };

    worker.onmessage = (event) => {
      if (event.data.type === 'ready') {
        sessions.set(sessionId, {
          worker,
          nextMsgId: 1,
          pending: new Map(),
          timeoutMs: null, // cached from first run/start call
        });
        resolve(sessionId);
        return;
      }
      // Route response to pending promise
      const session = sessions.get(sessionId);
      if (!session) return;
      const req = session.pending.get(event.data.id);
      if (req) {
        clearTimeout(req.timer);
        session.pending.delete(event.data.id);
        req.resolve(event.data);
      }
    };
  });
}
```

**`disposeSession` (clean teardown):**
```javascript
function disposeSession(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return;
  // Clear all pending timers and reject promises
  for (const req of session.pending.values()) {
    clearTimeout(req.timer);
    req.reject(new Error('Session disposed'));
  }
  session.pending.clear();
  session.worker.terminate();
  sessions.delete(sessionId);
}
```

### worker_src.js Changes

**No change to import strategy.** The static top-level `import` of
`monty.wasi-browser.js` stays. Each Worker independently loads the NAPI-RS
module (browser caches the .wasm fetch). This is simpler and more robust
than trying to inject a pre-compiled module.

The worker code remains as-is for Phase 2a. The only change is that
the bridge now creates multiple Workers instead of one.

### Dart Side Changes

**Key constraint:** `sessionId` lives in `WasmCoreBindings`, NOT in `MontyWasm`.
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
- `_jsSnapshot` returns `JSPromise<JSAny>` (NOT `JSString`) — see Snapshot Transfer

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
  Future<void> restoreSnapshot(Uint8List data) async {
    // MUST init session before restoring — _sessionId would be null otherwise
    await init();
    return _bindings.restore(_sessionId!, data);
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
- **CORRECTION:** `MontyWasm.restore()` creates a new `WasmCoreBindings`
  instance. `restoreSnapshot()` must call `init()` internally to ensure
  `_sessionId` is populated before routing to the bridge.

**MockWasmBindings (test mock):**
- Must be updated to implement new `createSession()` / `disposeSession()` methods
- Must accept `sessionId` on all method signatures

### Snapshot Transfer (Corrected — Round 2)

**NOT zero-copy.** `MontySnapshot.dump()` may return a `Uint8Array` view
into WASM linear memory. Marking the underlying `.buffer` as Transferable
would detach the WASM memory and crash the instance.

**CRITICAL: Must bypass JSON serialization.** `JSON.stringify(ArrayBuffer)`
returns `{}` — binary data is silently lost. `JSON.stringify(Uint8Array)`
returns a massive dictionary of index-to-byte strings. Neither works.

**Worker side — copy and transfer:**
```javascript
function handleSnapshot(id) {
  const bytes = activeSnapshot.dump();
  // MUST copy — bytes may be a view into WASM memory.
  // bytes.slice() returns a new TypedArray backed by its own ArrayBuffer.
  const copy = bytes.slice();
  self.postMessage({ type: 'result', id, ok: true, data: copy.buffer }, [copy.buffer]);
}
```

**Bridge side — return raw object, NOT JSON:**
```javascript
// snapshot() must NOT call JSON.stringify on the result.
// Return the raw JS object with ArrayBuffer directly to Dart.
async snapshot(sessionId) {
  const result = await callWorker(sessionId, { type: 'snapshot' }, timeoutMs);
  return result; // { ok: true, data: ArrayBuffer } — Dart reads via JSAny
}
```

**Dart side — read via `dart:js_interop`:**
```dart
// In WasmBindingsJs: _jsSnapshot returns JSPromise<JSAny>, not JSString
// Parse the JSAny to extract the ArrayBuffer property
```

This is dramatically faster than Base64 encoding (avoids the 33%
size expansion and string allocation overhead).

### Hard Timeout Design (Corrected — Round 2)

**Problem:** `resume()` and `snapshot()` don't receive `limitsJson`, so
the timeout duration is unknown for subsequent calls in an iterative session.

**Solution:** Cache the timeout on the session during the first `run()` or
`start()` call:
```javascript
async run(sessionId, code, limitsJson, scriptName) {
  const session = sessions.get(sessionId);
  if (limitsJson) {
    const limits = JSON.parse(limitsJson);
    // Hard backstop = soft timeout + 1 second buffer
    session.timeoutMs = (limits.timeout_ms || 30000) + 1000;
  }
  return callWorker(sessionId, { type: 'run', code, limitsJson, scriptName }, session.timeoutMs);
}

async resume(sessionId, valueJson) {
  const session = sessions.get(sessionId);
  // Re-use cached timeout from the start() call
  return callWorker(sessionId, { type: 'resume', valueJson }, session.timeoutMs);
}
```

**Race condition resolution:** The `clearTimeout(req.timer)` in `onmessage`
prevents the timeout from firing after a normal response. The timer is stored
per-message in `session.pending`, not globally.

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
| WASM binary requires atomics | Blocks removing COOP/COEP | Phase 3 (upstream recompilation) |
| Worker spawn latency (~200-500ms) | Slow session creation | Pre-warm pool; browser caches .wasm |
| Browser inconsistencies | terminate/compileStreaming | Test Chrome, Firefox, Safari |
| Timer precision without COOP/COEP | ~100μs clamping | Document; hard timeout backstop |
| Breaking WasmBindings API | All consumers + mocks must update | Single atomic commit |
| esbuild output format changes | Regex patch breaks | Build assertion catches; never use --minify |
| Worker crash (OOM/WASM trap) | Pending promises hang | `worker.onerror` handler rejects all pending |
| JSON.stringify on ArrayBuffer | Snapshot data silently lost | Bypass JSON for snapshot; return raw JSAny |

---

## Implementation Order

1. ~~**EXP-W1** — Patch build.js, rebuild assets, run tests (GATE)~~ DONE
2. ~~**Phase 1** — Formalize patch, commit~~ MERGED (PR #94)
3. **Phase 2a** — Multi-session bridge.js (JS only, Dart singleton still works)
   - Sessions Map, createSession, disposeSession, onerror handler
   - Hard timeout with timer-per-message and full cleanup
4. **Phase 2b** — Dart API changes (WasmBindings → WasmBindingsJs → WasmCoreBindings)
   - sessionId parameter threading
   - `restoreSnapshot` must call `init()` first
5. **Phase 2c** — Update MontyWasm + tests + mocks
6. **Phase 2d** — Hard timeout + supervision
   - Cache timeoutMs on session from first run/start call
7. **Phase 2e** — Snapshot binary transfer (replace Base64)
   - Worker: `bytes.slice()` + Transferable ArrayBuffer
   - Bridge: bypass JSON, return raw JS object
   - Dart: `JSAny` interop instead of `JSString`

---

## Review Gate History

| Date | Reviewer | Phase | Verdict | Findings |
|------|----------|-------|---------|----------|
| 2026-03-07 | gemini-3.1-pro | Plan v1 | NOT APPROVED | 3 fatal: module execution, WASM memory view, async factory |
| 2026-03-07 | gemini-3.1-pro | Phase 1 test coverage | NOT READY | 2 blockers: build assertion, memory growth test |
| 2026-03-08 | gemini-3.1-pro | Phase 1 shipped | APPROVED WITH CONDITIONS | Build assertion gap, test adequacy |
| 2026-03-08 | gemini-3.1-pro | Phase 2 plan | NOT APPROVED | 3 fatal: snapshot JSON, orphaned promises, restore init |

---

## File Change Manifest

### Phase 1 (MERGED)
| File | Change |
|------|--------|
| `packages/dart_monty_wasm/js/build.js` | Post-esbuild regex patch + build assertion |
| `test/fixtures/python_ladder/tier_16_memory_growth.json` | Memory growth test fixture |
| 5 ladder runner files | Added tier_16 to hardcoded tier lists |

### Phase 2
| File | Change |
|------|--------|
| `packages/dart_monty_wasm/js/src/bridge.js` | Singleton → sessions Map, createSession/disposeSession, onerror, hard timeout with timer-per-message |
| `packages/dart_monty_wasm/js/src/worker_src.js` | Snapshot: `bytes.slice()` + Transferable ArrayBuffer (Phase 2e) |
| `packages/dart_monty_wasm/js/build.js` | Rebuild assets after JS changes |
| `packages/dart_monty_wasm/lib/src/wasm_bindings.dart` | Add sessionId to all methods, add create/disposeSession |
| `packages/dart_monty_wasm/lib/src/wasm_bindings_js.dart` | JS interop for new bridge functions, sessionId params, `JSAny` for snapshot |
| `packages/dart_monty_wasm/lib/src/wasm_core_bindings.dart` | Own _sessionId, create in init(), restoreSnapshot calls init(), pass through all calls |
| `packages/dart_monty_wasm/lib/src/monty_wasm.dart` | No changes (session managed by WasmCoreBindings) |
| `packages/dart_monty_wasm/test/mock_wasm_bindings.dart` | Update mock for new API |
| `packages/dart_monty_wasm/test/monty_wasm_test.dart` | Update tests for session-aware API |
| `packages/dart_monty_wasm/test/wasm_core_bindings_test.dart` | Update tests for session lifecycle |
