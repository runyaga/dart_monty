## 0.6.1

- Update README with usage example and human/AI attribution
- Enrich `example/example.dart` with run, limits, external function dispatch, error handling, print capture, and snapshot/restore demos
- Extend `readme_doctest.dart` integration tests (6 → 20 tests)

## 0.6.0

- **BREAKING**: Migrate `MontyFfi` to `BaseMontyPlatform` (uses `MontyCoreBindings` architecture)
- Add `FfiCoreBindings` adapter
- Fix `restore()` to set restored instance to active state

## 0.4.3

- Version bump (no package code changes)

## 0.4.2

- Add async resume path with error handling in tier 13 ladder integration tests

## 0.4.1

- CI improvements (no package code changes)

## 0.4.0

- Handle `MONTY_PROGRESS_RESOLVE_FUTURES` tag (3) in progress dispatch
- Add `resumeAsFuture()` and `resolveFutures()` to `NativeBindings` and FFI implementation
- Implement `resolveFuturesWithErrors()` in `MontyFfi`

## 0.3.5

- Wire `kwargs`, `callId`, `methodCall` native accessors into pending progress results
- Forward `scriptName` through `run()` and `start()` to the native layer
- Parse `excType` and `traceback` from error JSON into `MontyException`
- Fix `_decodeRunResult` and `_handleProgress` error paths to parse full error JSON
- Treat empty kwargs `{}` from native layer as null (no kwargs)
- Read complete result JSON on progress error for rich exception details
- Add ladder integration tests for tiers 8 (kwargs), 9 (exceptions), 15 (scriptName)

## 0.3.4

- Initial release.
