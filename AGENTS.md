# Agents

Instructions for AI coding agents working on this repository.

## Quick Reference

```bash
dart pub get                              # Install dependencies
dart format .                             # Format all Dart files
dart analyze --fatal-infos                # Analyze (zero issues required)
dcm analyze .                             # DCM lint (see note: chronically red)
dart test                                 # Run unit tests
bash tool/gate.sh                         # Run ALL quality checks
```

See [Testing Guide](docs/contributor/testing.md) for more commands.

## Test Commands

### Dart unit tests
```bash
dart test                                 # All unit tests (VM)
dart test --run-skipped --tags=integration  # Integration suite (slow)
```

### FFI integration tests

**There is no Rust crate in this repo.** The native library, the oracle binary
and the WASM assets all live in `dart_monty_core`; this package consumes them
through the `dart_monty_core` dependency and its build hook. A stray untracked
`native/target/` directory may exist locally from an old layout — it is build
debris, not a crate, and `cd native && cargo build` fails with
`could not find Cargo.toml`.

```bash
dart test                                        # unit tests
dart test --run-skipped --tags=integration       # integration suite
dart test test/integration/ffi_file_io_test.dart \
  -p vm --run-skipped --tags=integration         # one file
```

**There is no `ffi` tag.** The tags declared in `dart_test.yaml` are
`integration`, `ladder` and `example` — all skipped by default, hence
`--run-skipped`. `dart test --tags=ffi` exits 79 with "No tests match the
requested tag selectors".

`tool/test_ffi.sh` is currently **broken**: it runs `dart test test/ffi/`, and
that directory does not exist.

`oracle_ffi_test.dart` and `wasm_fixture_test.dart` are **not in this repo** —
they are `dart_monty_core`'s conformance suites. Run them there.

Known-red, unrelated to any upgrade: 14 tests in
`test/experiments/event_loop_experiment_test.dart` fail with
`TimeoutException: EventLoopExtension never reached Waiting state` (file last
touched 2026-04-24). Everything else in the integration suite passes.

### JS compilation (dart2js)

**Always pass `--packages` when using `pubspec_overrides.yaml` path overrides:**

```bash
dart compile js \
  --packages=.dart_tool/package_config.json \
  example/web/bin/agent_demo.dart \
  -o example/web/web/agent_demo.dart.js
```

Without `--packages`, `dart compile js` uses its own package resolution that
**silently ignores** `pubspec_overrides.yaml` path overrides. It resolves
dependencies from the pub cache or git-cached version instead of your local
checkout. Symptoms:

- Source edits have no effect on the compiled output
- Syntax errors in overridden packages don't cause compilation failures
- The "Compiled N input bytes" count never changes between builds

This flag tells dart2js to use the same `.dart_tool/package_config.json` that
`dart pub get` writes, which respects path overrides.

### WASM fixture tests (requires Chrome + built WASM/JS)
```bash
# Full build + test (npm, cargo wasm32-wasip1, dart compile js):
bash tool/test_wasm.sh

# Skip rebuild when assets are already current:
bash tool/test_wasm.sh --skip-build

# NOTE: a bare `dart test -p chrome --run-skipped --tags=wasm` does NOT work —
# it tries to load every test/integration/*.dart file for chrome and several
# cannot compile there. Use tool/test_wasm.sh, or name the files explicitly.

# Run the standalone wasm_runner.dart (headless Chrome, no dart test):
# This uses a custom runner that prints FIXTURE_RESULT/FIXTURE_DONE lines.
# See tool/test_wasm.sh for the full pipeline — it compiles wasm_runner.dart
# to JS, serves it, and parses the output from Chrome.
```

### WASM oracle test
`wasm_fixture_test.dart` lives in **`dart_monty_core`**, not here. Run it from
that repo (`bash tool/test_wasm.sh` for the fixture corpus, or
`bash tool/test_wasm_unit.sh` for the `-p chrome` package:test suites).

This repo's own WASM coverage is `bash tool/test_wasm.sh`.

### Rust tests and linting
**Not applicable here — this repo has no Rust crate.** `cargo test`,
`cargo clippy` and `cargo fmt` belong to `dart_monty_core`; run them there.
`tool/test_rust.sh` in this repo drives the *core* crate via its checkout.


### Dart linting
```bash
dart analyze --fatal-infos                # Zero issues required
dcm analyze .                             # DCM rules (chronically red — 88 issues)
dart format --set-exit-if-changed .       # Format check
```

`dcm analyze .` reports **88 issues** (41 warning, 47 style); `dcm analyze lib`
— the narrower scope `tool/gate.sh` actually runs — reports **9**. Either way a
clean run is not the bar and never has been. Five steps
in `.github/workflows/dcm.yaml` carry `continue-on-error: true`, which means that
workflow cannot fail at all. `tool/dcm_ratchet.sh` (ported from `dart_monty_core`) is the gate instead: it
fails on any **new** issue above `tool/dcm-baseline.json`, while letting the
count fall freely. Regenerate deliberately with `bash tool/dcm_ratchet.sh --update`.

## Architecture

Pure Dart with compile-time conditional imports (no Flutter required).

- `lib/src/bridge/` -- high-level bridge with extensions and host functions
- `lib/src/runtime/` -- `MontyRuntime` and its handle/finalizer lifecycle
- `lib/src/host/`, `lib/src/os_call/` -- host functions and the OS-call surface
- `lib/src/extension/`, `lib/src/extensions/` -- extension registration
- `lib/src/web/` -- web-specific wiring

There is **no `lib/src/platform/`** in this repo. The platform abstraction and
its concrete FFI/WASM implementations both live in `dart_monty_core`.

See [Architecture Overview](docs/architecture/overview.md) for details.

## Development Rules

- Follow KISS, YAGNI, SOLID.
- Match surrounding code style exactly.
- Run `dart format` before committing.
- Keep this package pure Dart (no Flutter dependency).
- All JSON keys at the C FFI boundary must be `snake_case`.
- **Dispose:** `MontyRepl` and `MontyRuntime` must be disposed to avoid leaks.

## Commit Messages

Follow conventional commits: `<type>(<scope>): <description>`.
Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.
