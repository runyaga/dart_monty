## 0.6.1

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
