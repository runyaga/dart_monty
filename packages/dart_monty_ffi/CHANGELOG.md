## 0.3.5

- Wire `kwargs`, `callId`, `methodCall` native accessors into pending progress results
- Forward `scriptName` through `run()` and `start()` to the native layer
- Parse `excType` and `traceback` from error JSON into `MontyException`
- Fix `_decodeRunResult` and `_handleProgress` error paths to parse full error JSON
- Treat empty kwargs `{}` from native layer as null (no kwargs)
- Read complete result JSON on progress error for rich exception details
- Add ladder integration tests for tiers 8 (kwargs), 9 (exceptions), 15 (scriptName)
- Handle `MONTY_PROGRESS_RESOLVE_FUTURES` tag (3) in progress dispatch
- Add `resumeAsFuture()` and `resolveFutures()` to `NativeBindings` and FFI implementation
- Implement `resolveFuturesWithErrors()` in `MontyFfi`

## 0.3.4

- Initial release.
