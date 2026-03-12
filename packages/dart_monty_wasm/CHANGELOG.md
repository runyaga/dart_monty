## 0.9.0

- Make `bindings` parameter optional on `MontyWasm()` — defaults to `WasmBindingsJs()`
- No API changes for existing callers using explicit bindings

## 0.8.1

- Align version and dependency constraints for clean pub.dev release

## 0.8.0

- **BREAKING**: Replace NAPI-RS runtime with direct C-ABI calls to 28 exported Rust functions via `wasm32-wasip1`
- Eliminate SharedArrayBuffer/COOP/COEP requirement
- WASM binary drops from 256MB overhead to 4.5 MB
- Minimal WASI shim (6 imports), zero npm runtime dependencies
- New `wasm_glue.js` bridges main thread to Worker via direct C-ABI

## 0.7.0

- Multi-session Worker pool: `createSession`, `disposeSession`, `getDefaultSessionId`
- Strip NAPI-RS overhead: `asyncWorkPoolSize: 0`, `shared: false`, 16MB per session (was 256MB)
- Binary snapshot transfer via `Uint8Array` (avoid JSON serialization for snapshots)
- Timeout caching for repeated executions
- Wire cancel path: `disposeSession()` calls `Worker.terminate()` for preemptive kill
- Add WASM cancel benchmark (T1-1W, T1-4W, T2-2W, T3-1W + 5 N/A documented)
- Add `getDefaultSessionId` to production bridge.js export

## 0.6.1

- Fix `toSerializable()` in worker bridge for robust dict/set/bigint handling
  - Add circular reference guard (WeakSet) to prevent stack overflow
  - Add cross-realm Map/Set duck-typing via `.get` presence/absence
  - Convert Set → Array (Python frozenset/set from NAPI-RS)
  - Convert BigInt → Number/String (prevents JSON.stringify crash)
  - Convert TypedArray → Array (Python bytes from NAPI-RS)
- Update README with usage example and human/AI attribution
- Enrich `example/example.dart` with limits, external function dispatch, and error handling demos

## 0.6.0

- **BREAKING**: Migrate `MontyWasm` to `BaseMontyPlatform` (uses `MontyCoreBindings` architecture)
- Add `WasmCoreBindings` adapter

## 0.4.3

- Version bump (no package code changes)

## 0.4.2

- Version bump (no package code changes)

## 0.4.1

- CI improvements (no package code changes)

## 0.4.0

- Handle `resolve_futures` progress state in `MontyWasm`
- Add `pendingCallIds` field to `WasmProgressResult`
- Stub `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` with `UnsupportedError` (NAPI-RS does not expose FutureSnapshot API)

## 0.3.5

- Wire WASM JS bridge: kwargs, callId, scriptName, excType, and traceback in worker responses
- Fix worker onerror to reject pending promises on crash
- Fix `restore()` state machine to return active instance
- Add ladder tier files for tiers 8, 9, 15 to runner

## 0.3.4

- Initial release.
