## Unreleased

## 0.6.0

- **BREAKING**: Rename `dart_monty_desktop` to `dart_monty_native`
- **BREAKING**: Collapse `DartMontyWeb` to registration-only shim
- **BREAKING**: Add `BaseMontyPlatform` + `MontyCoreBindings` architecture
- Add `MontySession` API for state persistence (`run()`, `start()`, `resume()`)
- Add `MontyStateMixin` for shared state management across platforms
- Add capability interfaces (`MontyFutureCapable`, `MontySnapshotCapable`)
- Extract shared contract test harness (`LadderRunner`, `LadderAssertions`)
- Fix `restore()` to set restored instance to active state

## 0.4.3

- Fix vendored macOS dylib `install_name` pointing to CI runner path instead of `@rpath` (#47)
- Add `build.rs` to set `@rpath` install_name at compile time on macOS
- Add `install_name_tool` safety net in release CI workflow

## 0.4.2

- Plumb async/futures API through desktop Isolate bridge (`resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()`)
- Override async/futures methods in web plugin with `UnsupportedError`
- Add tier 4 function parameter fixtures (keyword-only, mixed args/kwargs, forwarding, positional-only)
- Enable tier 13 async ladder fixtures (remove xfail)
- Add "Async gather" and "Function params" examples to desktop and web example apps
- Expand web ladder runner to tiers 1-9, 13, 15

## 0.4.1

- Extract reusable publish workflow for all 6 packages
- Add path filters to skip CI on docs-only changes
- Extract enforce-coverage composite action (DRY)

## 0.4.0

- Add `MontyResolveFutures` progress variant for async/futures support (M13)
- Add `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` to platform API
- Add `MONTY_PROGRESS_RESOLVE_FUTURES` tag and `FutureSnapshot` handling in Rust C FFI
- Implement futures support in FFI and WASM packages (WASM stubs with `UnsupportedError`)
- Add tier 13 async/futures ladder fixtures (IDs 170-175)

## 0.3.5

- Add `scriptName`, `excType`, `traceback`, `kwargs`, `callId`, `methodCall` to data models
- Add Rust C FFI accessors and `script_name` parameter for richer run/start metadata
- Reject invalid UTF-8 in native FFI external function names and script names
- Wire FFI bindings to expose new native accessors to Dart
- Wire WASM JS bridge: kwargs, callId, scriptName, excType, and traceback in worker responses
- Fix worker onerror to reject pending promises on crash
- Fix `restore()` state machine to return active instance
- Fix FFI error paths to parse full error JSON (excType, traceback, filename)
- Add ladder test fixtures for tiers 8 (kwargs/callId), 9 (exceptions/traceback), 15 (scriptName)
- Xfail pre-existing try-except and syntax error ladder fixtures
- Add Flutter web plugin (dart_monty_web) with 52 unit tests
- Add Flutter web example app with sorting visualizer, TSP, and ladder runner
- Deploy Flutter web app to GitHub Pages at /flutter/

## 0.3.4

- Initial release.
