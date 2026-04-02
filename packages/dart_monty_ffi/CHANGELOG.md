## 0.8.4

- **B-1**: Emit `dart:developer` warning when zombie isolate count reaches
  threshold (3), aiding diagnosis of stuck executions

## 0.8.3

- Update `dart_monty_platform_interface` constraint to `^0.8.0` (fixes pub.dev
  downgrade test — `MontyCancelRegistry` and `monty_backend_spi.dart` require
  PI 0.8.0+)

## 0.8.2

- Make `bindings` parameter optional on `MontyFfi()` — defaults to `NativeBindingsFfi()`
- Enables zero-arg `MontyFfi()` construction for the `dart_monty` convenience API

## 0.8.1

- Align version with pub.dev (0.8.0 was not successfully published)
- Update platform_interface dependency constraint to `^0.7.0`

## 0.8.0

- **BREAKING**: Migrate from `DynamicLibrary.open()` to `@Native` annotations with Dart native build hooks
- Add `hook/build.dart` — automatic native library resolution via contributor/consumer dual-path strategy
- Contributors: `cargo build --release` runs automatically when `native/Cargo.toml` exists
- Consumers: pre-built binaries download from GitHub Releases (atomic `.tmp` downloads with content-length validation)
- Remove `NativeLibraryLoader` and `libraryPath` parameter from all constructors
- `dart test` and `dart run` now work with zero environment variables or manual configuration
- Graceful fallback for iOS/Android targets (no crash, deferred to future PR)
- Add `-headerpad_max_install_names` to `build.rs` for macOS dylib rewriting
- Add `docs/native_build.md` documenting the build architecture

## 0.7.0

- Add `MontyNative`, `NativeIsolateBindings`, and `NativeIsolateBindingsImpl` (moved from `dart_monty_native`)
- The Isolate bridge is now usable without Flutter, enabling CLI tools and non-Flutter Dart applications
- Wire CancellableTracker: `cancel()` sets atomic flag via FFI, `terminate()` with 5s timeout + zombie tracking
- Fix `dispose()` hang on stuck FFI — now calls `cancel()` first to unblock interpreter (#113)
- Fix TOCTOU race in handle lifecycle, handle leak on error paths
- Add cancel experiment suite (9 experiments, JIT + AOT benchmark harness)
- Commit generated FFI bindings for git-based dependency resolution

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
