## Unreleased

## 0.6.0

- **BREAKING:** Collapse `DartMontyWeb` from a full `MontyPlatform` pass-through to a registration-only shim
- Remove `extends MontyPlatform`, all delegating methods, and `withBindings()` test constructor
- All execution now handled directly by `MontyWasm` from `dart_monty_wasm`
- Remove `meta` and `web` dependencies (no longer imported)
- Replace 846 lines of delegation tests with a single registration test

## 0.4.3

- Version bump (no package code changes)

## 0.4.2

- Override `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` in `DartMontyWeb` with `UnsupportedError`
- Expand web ladder runner to tiers 1-9, 13, 15 with `nativeOnly` skip handling

## 0.4.1

- CI improvements (no package code changes)

## 0.4.0

- Bump dependency constraints for 0.4.0 release

## 0.3.5

- Thread `scriptName` parameter through `run()` and `start()`
- Add @visibleForTesting constructor for dependency injection
- Add 52 unit tests covering all API methods
- Add CI job and pre-commit hooks

## 0.3.4

- Initial release.
