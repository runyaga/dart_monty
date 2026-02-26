## Unreleased

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
