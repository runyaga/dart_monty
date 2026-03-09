## 0.7.0

- Add sealed `MontyError` hierarchy: `MontyCancelledError`, `MontyDisposedError`, `MontyScriptError`, `MontyPanicError`, `MontyCrashError`, `MontyResourceError`
- Add `MontyCancelToken` extension type for cross-isolate cancellation via `cancelById`/`isHandleAlive`
- Add `BaseMontyPlatform.cancelById` and `isHandleAlive` static methods
- Fix TOCTOU race in handle lifecycle and sync throw deadlock in iterative execution
- Remove dead `inputs` parameter from platform interface
- Plumb `printOutput` through iterative and WASM execution paths

## 0.6.1

- Update README with human/AI attribution
- Enrich `example/example.dart` with all model types, error variants, traceback frames, and sealed-type pattern matching

## 0.6.0

- **BREAKING**: Extract state machine into `MontyStateMixin` (reduces per-platform duplication)
- **BREAKING**: Add `BaseMontyPlatform` with shared translation logic
- **BREAKING**: Add `MontyCoreBindings`, `CoreRunResult`, `CoreProgressResult` architecture
- **BREAKING**: Add capability interfaces (`MontyFutureCapable`, `MontySnapshotCapable`)
- Add `MontySession` API for session management (`run()`, `start()`, `resume()`)
- Extract shared test harness (`LadderRunner`, `LadderAssertions`) into `dart_monty_testing` barrel
- Mock & API surface cleanup
- Prune tautological tests and unused dependencies

## 0.4.3

- Version bump (no package code changes)

## 0.4.2

- Version bump (no package code changes)

## 0.4.1

- CI improvements (no package code changes)

## 0.4.0

- Add `MontyResolveFutures` sealed variant with `pendingCallIds`
- Add `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` to `MontyPlatform`
- Update `MockMontyPlatform` with invocation tracking for new async methods

## 0.3.5

- Add `scriptName` parameter to `run()` and `start()`
- Add `excType` and `traceback` fields to `MontyException`
- Add `MontyStackFrame` model for structured traceback frames
- Add `kwargs`, `callId`, `methodCall` fields to `MontyPending`
- Update `MockMontyPlatform` to capture new parameters

## 0.3.4

- Initial release.
