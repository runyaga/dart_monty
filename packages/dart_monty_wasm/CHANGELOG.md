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
