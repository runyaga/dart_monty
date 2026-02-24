## Unreleased

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
