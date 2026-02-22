# M3B: Web Viability Spike

**Status: COMPLETE — GO**

## Goal

Prove Dart can call into Monty WASM in a browser via JS interop.
GO/NO-GO decision for web support.

## Result

**GO.** Dart successfully calls `@pydantic/monty` WASM in a browser via
`dart:js_interop` through a Web Worker bridge. All test cases pass.

## Risk Addressed

- **R1** (web WASM/WASI viability) — **validated**, web support is viable

## Prerequisites

- M2 (Rust C FFI + WASM build) complete
- M3A (Native FFI package) complete

## Architecture

```text
Browser (index.html + COOP/COEP HTTP headers)
  |
  +-- monty_bundle.js (IIFE, sets window.montyBridge)
  |     |
  |     +-- monty_glue.js — thin postMessage bridge to Worker
  |
  +-- monty_worker.js (ESM, bundled by esbuild from monty_worker_src.js)
  |     |
  |     +-- @pydantic/monty-wasm32-wasi — NAPI-RS WASM loader
  |     +-- wasi-worker-browser.mjs — WASI sub-worker (SharedArrayBuffer)
  |     +-- monty.wasm32-wasi.wasm — 12MB Monty WASM binary
  |
  +-- main.dart.js (compiled from Dart via dart compile js)
        |
        +-- dart:js_interop -> calls window.montyBridge.run(), etc.
```

Key design decisions:

- **Web Worker** — Chrome has an 8MB synchronous WASM compile limit on the
  main thread. The 12MB Monty WASM binary must be compiled inside a Worker.
- **`dart compile js`** (not `dart compile wasm`) — simpler loader for a spike;
  Dart-to-WASM compilation is orthogonal and can be added in M4.
- **NAPI-RS factory pattern** — raw WASM exports use `Monty.create(code, opts)`
  static factory, not `new Monty(code)`. Error results are returned as
  `instanceof` checks (MontyException, MontyTypingError), not thrown.
- **COOP/COEP HTTP headers** required for SharedArrayBuffer (WASM threads).
  Meta tags do not work; must be response headers from the server.

## Deliverables

- `spike/web_test/bin/main.dart` — Dart entry point using `dart:js_interop`
- `spike/web_test/web/index.html` — HTML host page
- `spike/web_test/web/monty_glue.js` — main-thread bridge (window.montyBridge)
- `spike/web_test/web/monty_worker_src.js` — Worker source (WASM host)
- `spike/web_test/package.json` — npm deps (@pydantic/monty + NAPI-RS runtime)
- `spike/web_test/pubspec.yaml` — Dart package config
- `tool/test_web_spike.sh` — automated build + headless Chrome verification

## Test Results

| Test | Result |
|------|--------|
| `run("2 + 2")` | PASS: `4` |
| `run('"hello " + "world"')` | PASS: `hello world` |
| `run("invalid syntax def")` | PASS: SyntaxError (expected) |
| `start()` with external fn `fetch` | PASS: MontyPending with args |
| `resume()` with mock value | PASS: MontyComplete |

## Work Items

### 3B.1 Web Spike Implementation

- [x] `spike/web_test/bin/main.dart` using `dart:js_interop`
- [x] `spike/web_test/web/index.html` (COOP/COEP via server headers)
- [x] `spike/web_test/web/monty_glue.js` — Worker bridge
- [x] `spike/web_test/web/monty_worker_src.js` — WASM host in Worker
- [x] Compile: `dart compile js bin/main.dart -o web/main.dart.js`
- [x] Verify: Python code executes in browser via Dart JS -> Worker -> Monty WASM

### 3B.2 Web Spike Automation

- [x] `tool/test_web_spike.sh`:
  1. `npm install` (with NAPI-RS runtime deps)
  2. `esbuild` bundle worker (resolve npm imports) + patch sub-worker URL
  3. `esbuild` bundle glue (IIFE for main thread)
  4. `dart compile js` the spike
  5. Start Python server with COOP/COEP headers
  6. Run headless Chrome, capture console output
  7. Assert GO result

## Key Technical Findings

1. `@pydantic/monty` npm package (v0.0.7) ships NAPI-RS bindings with a
   `wasm32-wasi` target. The WASM binary is 12MB.
2. NAPI-RS classes use static `.create()` factories, not constructors.
   `new Monty(code)` fails with "Class contains no constructor".
3. esbuild cannot resolve `new URL()` bare specifiers — manual post-bundle
   patching required for the sub-worker URL.
4. `--virtual-time-budget` in headless Chrome freezes Worker real timers.
   Use `timeout` instead for Worker-based tests.
5. npm install requires `--force` for the `wasm32-wasi` platform package
   (CPU architecture mismatch on host).

## Decision

| Outcome | Action |
|---------|--------|
| **Web spike passes** | **Proceed to M4 (Dart WASM package) and M6 (Flutter web)** |
| Web spike fails (fixable) | Investigate, document fix, retry |
| Web spike fails (fundamental) | Drop web phases, native-only project |
