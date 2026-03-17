## 0.8.0

### Changed

- Upgrade Monty Rust crate from 0.0.7 to 0.0.8 — includes compiler
  stack-depth fixes (#246, #268), full math module, PEP 448 unpacking,
  NameLookup auto-detection, `re` module, dict views, and more
- Adapt FFI handle layer for PrintWriter by-value API change

### Fixed

- ForIter stack corruption in nested for-loops with try/except
  (3+ loops, try in 2+, 4+ items in 3rd loop) — dart_monty#225

## 0.7.4

- Update `dart_monty_platform_interface` constraint to `^0.8.0`
- Update `dart_monty_ffi` constraint to `^0.8.3`

## 0.7.3

- Update `dart_monty_ffi` dependency constraint to `^0.8.1`

## 0.7.2

- Update `dart_monty_ffi` dependency constraint to `^0.8.0`

## 0.7.1

- Suppress `MontyPlatform.instance` deprecation in `registerWith()` (federated plugin registration requires the singleton)

## 0.7.0

- Extract `MontyNative`, `NativeIsolateBindings`, and `NativeIsolateBindingsImpl` to `dart_monty_ffi`
- Re-export moved classes for backward compatibility
- `dart_monty_native` now serves only as the Flutter plugin registration shim
- Wire CancellableTracker into native FFI cancel API (atomic flag in Monty bytecode loop)
- Migrate to `runyaga/monty` fork with NameLookup handled internally in Rust

## 0.6.1

- Update README with usage section and human/AI attribution
- Update `example/example.dart` doc comments

## 0.6.0

- **BREAKING**: Rename package from `dart_monty_desktop` to `dart_monty_native`
- Rename `MontyDesktop` -> `MontyNative`, `DesktopBindings` -> `NativeIsolateBindings`, `DesktopBindingsIsolate` -> `NativeIsolateBindingsImpl`
- Desktop & WASM refinement + iOS preparation
- Consolidate Rust crate duplication
- Add `MontySession` native integration tests
- Prepares for platform expansion (Windows, iOS, Android)

## 0.4.3

- Fix vendored macOS dylib `install_name` pointing to CI runner path instead of `@rpath` (#47)
- Rebuild native library with correct `@rpath` install_name

## 0.4.2

- Add `resumeAsFuture()`, `resolveFutures()`, `resolveFuturesWithErrors()` to `DesktopBindings`, `DesktopBindingsIsolate`, and `MontyDesktop`
- Add mock desktop bindings for async/futures methods
- Add async/futures integration tests for tier 13 ladder fixtures

## 0.4.1

- CI improvements (no package code changes)

## 0.4.0

- Bump dependency constraints for 0.4.0 release

## 0.3.5

- Thread `scriptName` parameter through `run()` and `start()`

## 0.3.4

- Initial release.
