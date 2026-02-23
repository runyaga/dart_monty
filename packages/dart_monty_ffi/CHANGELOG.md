## Unreleased

## 0.4.0

- Wire `kwargs`, `callId`, `methodCall` native accessors into pending progress results
- Forward `scriptName` through `run()` and `start()` to the native layer
- Parse `excType` and `traceback` from error JSON into `MontyException`
- Fix `_decodeRunResult` and `_handleProgress` error paths to parse full error JSON
- Treat empty kwargs `{}` from native layer as null (no kwargs)
- Read complete result JSON on progress error for rich exception details
- Add ladder integration tests for tiers 8 (kwargs), 9 (exceptions), 15 (scriptName)

## 0.3.5

- Version bump for M6 milestone alignment

## 0.3.4

- Initial release.
