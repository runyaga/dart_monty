# dart_monty - Integration Plan

**Dart first, Flutter last.** Pure Dart packages through M4. Flutter
layered on in M5+. Risk driven out early (C FFI, web WASM, snapshots
validated in M2-M3 before any Flutter investment).

Detailed specs: [`docs/milestones/`](docs/milestones/)

---

## Quality Gates (every milestone)

Every milestone must pass before proceeding to the next:

| Gate | Requirement |
|------|------------|
| `dart format --set-exit-if-changed .` | Zero formatting issues |
| `dart analyze --fatal-infos` / `flutter analyze --fatal-infos` | Zero warnings, zero infos |
| `cargo fmt --check && cargo clippy -- -D warnings` | Zero Rust warnings (M2+) |
| Unit test coverage | >= 90% line coverage |
| Integration tests | 100% automated, pass in CI |
| Python compatibility ladder | All tiers at or below current milestone pass on all paths |
| `tool/test_m<N>.sh` | Single script runs all checks for milestone N |

---

## Python Compatibility Ladder

A **growing test suite** of increasingly complex Python code validated
on **every execution path** (native FFI, WASM, Flutter Isolate). New
tiers are added as Monty gains features. Fixtures live in
`test/fixtures/python_ladder/` as numbered JSON files -- drop a file in,
the test runner picks it up automatically.

| Tier | Feature | Gate |
|------|---------|------|
| 1 | Expressions (`2+2`, f-strings, booleans) | M3 |
| 2 | Variables + Collections (list, dict, set, tuple, range) | M3 |
| 3 | Control Flow (for, while, comprehensions, ternary) | M3 |
| 4 | Functions (def, recursion, defaults, `*args`, lambda, closures) | M3 |
| 5 | Error Handling (try/except, invalid syntax) | M3 |
| 6 | External Functions (poll/resume, resume-with-error) | M3 |
| 7 | Classes and instances | When Monty adds support |
| 8 | Async/await | When Monty async stabilizes |
| 9 | Dataclasses | When available |
| 10 | Generators and iterators | When available |
| 11 | Match statements | When available |
| 12 | Stdlib modules (json, sys) | When available |

**Every milestone M3+ must pass all unlocked tiers on all its paths.**

---

## Milestones

### M1: Pure Dart Platform Interface

> [Full spec: `docs/milestones/M1.md`](docs/milestones/M1.md)

- [ ] `MontyResult`, `MontyProgress` (sealed), `MontyLimits`, `MontyResourceUsage`, `MontyException`
- [ ] JSON serialization, equality, `toString()` for all value types
- [ ] `MontyPlatform` abstract class (run, start, resume, resumeWithError, snapshot, restore, dispose)
- [ ] `MockMontyPlatform` with canned responses
- [ ] Unit tests: 90%+ coverage

**Gate:**
```bash
tool/test_m1.sh
# Runs: dart pub get, dart format, dart analyze, dart test --coverage
# Asserts: coverage >= 90%, zero warnings
```

---

### M2: Rust C FFI Layer + WASM Build

> [Full spec: `docs/milestones/M2.md`](docs/milestones/M2.md)

- [ ] `native/Cargo.toml` edition 2024, `monty` pinned to git rev, `Cargo.lock` committed
- [ ] `rust-toolchain.toml` pinning stable Rust
- [ ] `extern "C"` API: create, free, run, start, resume, resume_with_error, snapshot, restore, limits
- [ ] `native/include/dart_monty.h` hand-written C header
- [ ] `catch_unwind` at every FFI boundary, NULL checks, error as C strings
- [ ] WASM build from same source (`cargo build --target wasm32-wasip1-threads`)
- [ ] Verify "resume with error" upstream support
- [ ] Rust tests: 90%+ coverage (`cargo-tarpaulin`)
- [ ] Integration tests: smoke, iterative execution, snapshots, panic safety, resource limits, WASM smoke

**Gate:**
```bash
tool/test_m2.sh
# Runs: cargo fmt, cargo clippy, cargo test, cargo tarpaulin
# Runs: cargo build --release (native + WASM)
# Runs: node test/wasm_smoke.js (WASM integration)
# Asserts: coverage >= 90%, all tests green, both binaries produced
```

---

### M3: Pure Dart FFI + Web Spike + Ladder Tiers 1-6

> [Full spec: `docs/milestones/M3.md`](docs/milestones/M3.md)

- [ ] `ffigen.yaml` + generated Dart bindings from C header
- [ ] `Monty` class implementing `MontyPlatform` via `dart:ffi`
- [ ] `NativeFinalizer`, pointer lifecycle, JSON encode/decode
- [ ] Iterative execution: start/resume/resumeWithError in Dart
- [ ] Snapshots: `snapshot()` -> `Uint8List`, `Monty.restore()`
- [ ] **Web viability spike**: `dart compile wasm` + `dart:js_interop` + Monty WASM in browser
- [ ] **Cross-path parity test**: same Python through native FFI and WASM, identical results
- [ ] **Python ladder tiers 1-6**: expressions, variables, control flow, functions, errors, external fns -- on both paths
- [ ] **Snapshot portability test**: native <-> WASM round-trip
- [ ] Unit tests (mock FFI): 90%+ coverage
- [ ] Integration tests: native FFI, web spike, parity, ladder, snapshots -- all automated

**Gate:**
```bash
tool/test_m3.sh
# Runs: dart format, dart analyze, dart test --coverage (mock)
# Runs: cargo build --release (native)
# Runs: DYLD_LIBRARY_PATH=... dart test --tags=integration
# Runs: dart compile wasm spike/web_test/main.dart
# Runs: node tool/serve_coep.js & chromium --headless spike/web_test/
# Runs: tool/test_cross_path_parity.sh
# Runs: tool/test_python_ladder.sh --paths=native,wasm --tiers=1-6
# Runs: tool/test_snapshot_portability.sh
# Asserts: coverage >= 90%, all green, ladder tiers 1-6 pass on both paths
```

**DECISION POINT:** Web spike result determines M4/M6 viability.

---

### M4: Pure Dart WASM Package + Ladder on WASM

> [Full spec: `docs/milestones/M4.md`](docs/milestones/M4.md)
>
> **Prerequisite:** M3 web spike passed.

- [ ] `packages/dart_monty_wasm/js/wrapper.js` -- loads Monty WASM, exposes global bridge
- [ ] JS bundling via esbuild (`package.json` + build script)
- [ ] `dart:js_interop` bindings for `window.DartMontyBridge`
- [ ] `MontyWasm` class implementing `MontyPlatform`
- [ ] All execution async (web is inherently async)
- [ ] **Python ladder tiers 1-6+** through `dart_monty_wasm` in headless Chrome
- [ ] Browser integration tests: 90%+ coverage

**Gate:**
```bash
tool/test_m4.sh
# Runs: npm install && npm run build (JS wrapper)
# Runs: dart format, dart analyze
# Runs: dart test --platform chrome --coverage
# Runs: tool/test_python_ladder.sh --paths=wasm-package --tiers=1-6
# Asserts: coverage >= 90%, browser tests green, ladder passes
```

---

### M5: Flutter Desktop Plugin (macOS + Linux) + Ladder via Isolate

> [Full spec: `docs/milestones/M5.md`](docs/milestones/M5.md)
>
> First Flutter-dependent code.

- [ ] Federated plugin: root `default_package`, desktop `flutter.plugin.implements`
- [ ] Native bundling: `.podspec` (macOS), `CMakeLists.txt` (Linux)
- [ ] `FlutterMonty` class: background `Isolate`, `SendPort`/`ReceivePort`
- [ ] External function callbacks via Isolate message passing
- [ ] `example/` Flutter app (code input, run, output, resource usage)
- [ ] **Python ladder tiers 1-6+** through `FlutterMonty` Isolate on macOS and Linux
- [ ] Widget tests + Isolate lifecycle integration tests: 90%+ coverage

**Gate:**
```bash
tool/test_m5.sh
# Runs: tool/build_native.sh (build + copy to platform dirs)
# Runs: dart format, flutter analyze
# Runs: flutter test packages/dart_monty_desktop --coverage
# Runs: flutter test example/
# Runs: tool/test_python_ladder.sh --paths=flutter-isolate --tiers=1-6
# Runs: flutter build macos (build smoke)
# Asserts: coverage >= 90%, all tests green, ladder passes via Isolate
```

---

### M6: Flutter Web Plugin + Ladder in Browser

> [Full spec: `docs/milestones/M6.md`](docs/milestones/M6.md)
>
> **Prerequisite:** M4 complete.

- [ ] Federated registration: `default_package: dart_monty_web`
- [ ] Wraps `dart_monty_wasm` (pure Dart, from M4)
- [ ] Script injection in `registerWith()`
- [ ] COOP/COEP deployment documentation
- [ ] **Python ladder tiers 1-6+** through Flutter web in headless Chrome
- [ ] Browser integration tests: 90%+ coverage

**Gate:**
```bash
tool/test_m6.sh
# Runs: dart format, flutter analyze
# Runs: flutter test --platform chrome packages/dart_monty_web --coverage
# Runs: tool/test_python_ladder.sh --paths=flutter-web --tiers=1-6
# Runs: flutter build web (build smoke)
# Asserts: coverage >= 90%, browser tests green, ladder passes
```

---

### M7: Windows + Mobile (iOS + Android) + Ladder on All Platforms

> [Full spec: `docs/milestones/M7.md`](docs/milestones/M7.md)
>
> CI/build targets. Dart logic identical to M5.

- [ ] Windows: `x86_64-pc-windows-msvc`, `CMakeLists.txt`, CI test
- [ ] iOS: `aarch64-apple-ios`, static lib, XCFramework, podspec, CI simulator test
- [ ] Android: cargo-ndk per ABI, `jniLibs/`, Gradle, CI emulator test
- [ ] Same `FlutterMonty` Isolate pattern (only library loading differs)
- [ ] **Python ladder tiers 1-6+** on Windows, iOS simulator, Android emulator
- [ ] 90%+ coverage per platform

**Gate:**
```bash
tool/test_m7.sh
# Runs per platform (CI matrix):
#   cargo build --release --target <target>
#   flutter test --coverage
#   tool/test_python_ladder.sh --paths=<platform> --tiers=1-6
#   flutter build <platform>
# Asserts: coverage >= 90%, ladder passes on all platforms
```

---

### M8: Hardening + Cross-Platform Testing + Full Ladder

> [Full spec: `docs/milestones/M8.md`](docs/milestones/M8.md)

- [ ] Stress tests: concurrent, large inputs, recursion, rapid lifecycle
- [ ] Comprehensive snapshot portability: native <-> WASM <-> Python <-> JS
- [ ] Performance benchmarks: FFI overhead, Isolate overhead, WASM overhead
- [ ] Memory leak detection (valgrind/leaks)
- [ ] **Python ladder: all unlocked tiers on all paths** (full matrix)
- [ ] 90%+ coverage across all packages
- [ ] `docs/benchmarks.md` published

**Gate:**
```bash
tool/test_m8.sh
# Runs: tool/test_all.sh (every platform)
# Runs: tool/test_stress.sh
# Runs: tool/test_python_ladder.sh --paths=all --tiers=all
# Runs: tool/test_snapshots.sh (full portability matrix)
# Runs: tool/benchmark.sh
# Asserts: all pass, all coverage >= 90%, no memory leaks, full ladder green
```

---

### M9: Advanced Features (incremental)

> [Full spec: `docs/milestones/M9.md`](docs/milestones/M9.md)

- [ ] 9.1 REPL mode (C API + Dart class + Flutter widget)
- [ ] 9.2 Type checking (ty integration via C API)
- [ ] 9.3 Snapshot persistence helpers (device storage, cloud sync)
- [ ] 9.4 External function registry (declarative, auto-marshalling)
- [ ] 9.5 DevTools extension (bytecode viewer, resource monitoring)

Each sub-milestone independently gated at 90%+ coverage + ladder.

---

## Phase Ordering Rationale

```text
Pure Dart (no Flutter SDK required):
  M1  Types + contract           ← low risk, establishes API
  M2  Rust C FFI + WASM build    ← drives out R3, R4, R5 (hardest Rust work)
  M3  Dart FFI + web spike       ← drives out R1, R2 (GO/NO-GO on web)
      + ladder tiers 1-6           validates real Python on both paths
  M4  Dart WASM package           ← full web impl (pure Dart, no Flutter)

Flutter (layered on top):
  M5  Flutter desktop             ← first Flutter code (Isolate + plugin wiring)
  M6  Flutter web                 ← thin wrapper around M4
  M7  Windows + mobile            ← CI/build targets, same Dart code
  M8  Hardening                   ← stress, snapshots, benchmarks, full ladder
  M9  Advanced                    ← REPL, type checking, DevTools
```

Risks R1-R5 resolved by M3. Python ladder validates real code on every
path from M3 onward. Flutter work begins only after all unknowns answered.

---

## Automated Test Scripts

Every milestone has a single `tool/test_m<N>.sh` script. CI runs these.
No manual testing steps.

| Script | What it automates |
|--------|-------------------|
| `tool/test_m1.sh` | format + analyze + dart test + coverage |
| `tool/test_m2.sh` | cargo fmt/clippy/test/tarpaulin + native + WASM build + WASM smoke |
| `tool/test_m3.sh` | format + analyze + mock tests + native build + FFI integration + web spike + parity + ladder tiers 1-6 + snapshots |
| `tool/test_m4.sh` | npm build + format + analyze + browser tests + ladder via wasm-package |
| `tool/test_m5.sh` | native build + format + analyze + flutter test + ladder via Isolate + build smoke |
| `tool/test_m6.sh` | format + analyze + flutter test (Chrome) + ladder via flutter-web + build smoke |
| `tool/test_m7.sh` | per-platform: cross-compile + flutter test + ladder + build smoke |
| `tool/test_m8.sh` | all platforms + stress + full ladder + snapshots + benchmarks + leaks |
| `tool/test_python_ladder.sh` | runs ladder fixtures on specified paths and tiers |
| `tool/test_all.sh` | runs test_m1 through test_m8 sequentially |

### Test Dependencies (installed once)

| Tool | Used By | Purpose |
|------|---------|---------|
| Dart SDK | M1-M4 | Pure Dart compilation + testing |
| Rust stable (>= 1.85.0) | M2+ | Native + WASM compilation |
| `cargo-tarpaulin` | M2+ | Rust coverage |
| Node.js or Bun | M2-M4, M6 | WASM smoke tests, JS wrapper build, COEP server |
| Chrome (headless) | M3-M4, M6 | Browser integration tests |
| Flutter SDK | M5+ | Plugin testing |
| `cargo-ndk` | M7 | Android cross-compilation |
| Xcode | M7 | iOS builds |
| `pydantic-monty` (Python) | M8 | Cross-platform snapshot tests |

---

## When You Resume

To start implementation, type:

```
Start M1. Implement dart_monty_platform_interface with all value types,
MontyPlatform contract, MockMontyPlatform, and tests. Gate: tool/test_m1.sh
passes with 90%+ coverage.
```
