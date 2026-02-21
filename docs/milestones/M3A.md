# M3A: Native FFI Package

## Goal

Pure Dart `dart_monty_ffi` package that loads the native Rust library and
exposes the full `MontyPlatform` interface via `dart:ffi`.

## Risk Addressed

- Proves Dart FFI pointer lifecycle is correct (allocate / call / free)
- Validates JSON contract between Rust C API and Dart types

## Deliverables

- `packages/dart_monty_ffi` — pure Dart package (no Flutter SDK dependency)
- `NativeBindings` abstract interface (int-handle based, mockable)
- `NativeBindingsFfi` real FFI implementation (pointer lifecycle, NativeFinalizer)
- `NativeLibraryLoader` platform-aware `.dylib`/`.so`/`.dll` resolution
- `MontyFfi` implementing `MontyPlatform` with state machine
- Mock-based unit tests (>= 90 % line coverage, no native lib required)
- Tagged integration tests (require native lib + `DYLD_LIBRARY_PATH`)
- `tool/test_m3a.sh` gate script

## Architecture

```text
MontyFfi (implements MontyPlatform)
  |  state machine: idle -> active -> disposed
  |  JSON encode/decode via platform_interface types
  |
  +-- NativeBindings (abstract, int-based handles)
  |     |
  |     +-- NativeBindingsFfi (real FFI, pointer lifecycle, NativeFinalizer)
  |     |     +-- DartMontyBindings (ffigen-generated)
  |     |           +-- DynamicLibrary (from NativeLibraryLoader)
  |     |
  |     +-- MockNativeBindings (test only)
  |
  +-- NativeLibraryLoader (static, platform-aware path resolution)
```

## State Machine

| State | Valid methods | Transitions |
|-------|-------------|-------------|
| idle | `run()`, `start()`, `restore()`, `dispose()` | run->idle, start->active/idle, restore->new idle, dispose->disposed |
| active | `resume()`, `resumeWithError()`, `snapshot()`, `dispose()` | resume->active/idle, snapshot->active, dispose->disposed |
| disposed | none (all throw StateError) | terminal |

## Work Items

### 3A.1 Package Structure

- [x] Remove Flutter SDK deps from `pubspec.yaml` (pure Dart)
- [x] `ffigen.yaml` pointing to `native/include/dart_monty.h`
- [x] `.gitignore` excluding `lib/src/generated/`
- [x] `tool/generate_bindings.sh` script
- [x] Barrel export `lib/dart_monty_ffi.dart`

### 3A.2 NativeBindings Interface

- [x] Abstract class with int-handle signatures for all 17 C functions
- [x] No `Pointer<T>` types — keeps interface pure Dart, mocking trivial

### 3A.3 NativeLibraryLoader

- [x] Platform-aware `.dylib`/`.so`/`.dll` resolution
- [x] Override support for `DART_MONTY_LIB_PATH` env var and test injection

### 3A.4 MontyFfi Implementation

- [x] Implements `MontyPlatform` from platform_interface
- [x] State machine: idle -> active -> disposed
- [x] `run()` is stateless (creates transient handle, runs, frees, returns to idle)
- [x] `start()` stores handle for subsequent `resume()` calls
- [x] `inputs` parameter -> `UnsupportedError` if non-null/non-empty
- [x] JSON encode/decode using platform_interface types

### 3A.5 NativeBindingsFfi (Real FFI)

- [x] `DynamicLibrary` loading via `NativeLibraryLoader`
- [x] Pointer lifecycle: allocate out-params, read C strings, free with `monty_string_free`/`monty_bytes_free`
- [x] `NativeFinalizer` for leak prevention

### 3A.6 Unit Tests (mock-based)

- [x] `MockNativeBindings` with configurable returns + call tracking
- [x] `run()`: OK, error, with limits, inputs->UnsupportedError, wrong state
- [x] `start()`: complete immediately, pending, error, with ext fns, wrong state
- [x] `resume()`: pending->complete, pending->pending, error, wrong state
- [x] `resumeWithError()`: complete after error, wrong state
- [x] `snapshot()`: returns bytes, wrong state
- [x] `restore()`: returns new MontyFfi, error case
- [x] `dispose()`: frees handle, double-dispose safe, disposed rejects all
- [x] State machine: full transition coverage

### 3A.7 Integration Tests (tagged)

- [x] Smoke: `run("2+2")` -> 4
- [x] Iterative: start with ext fn -> MontyPending -> resume -> MontyComplete
- [x] Resume with error: start -> pending -> resumeWithError -> error propagation
- [x] Snapshot round-trip: run -> snapshot -> restore -> run same code -> same result
- [x] Resource limits: set memory limit -> allocating code -> verify error
- [x] Error handling: invalid syntax -> MontyException with source location
- [x] Dispose safety: dispose twice without crash
- [x] UTF-8 boundaries: emoji/multibyte strings through FFI round-trip
- [x] Multiple instances: two MontyFfi simultaneously, no state bleed
- [x] Memory stability: 100-iteration create->run->dispose loop

### 3A.8 Gate Script

- [x] `tool/test_m3a.sh`: format, analyze, test, coverage >= 90 %

## Quality Gate

```bash
# Unit tests (no native lib):
bash tool/test_m3a.sh

# Integration tests (requires M2 native lib built):
cd native && cargo build --release && cd ..
cd packages/dart_monty_ffi
DYLD_LIBRARY_PATH=../../native/target/release dart test --tags=integration
```
