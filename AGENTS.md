# Agents

Instructions for AI coding agents working on this repository.

## Quick Reference

```bash
dart pub get                              # Install dependencies
dart format .                             # Format all Dart files
dart analyze --fatal-infos                # Analyze (zero issues required)
dcm analyze .                             # DCM lint (zero issues required)
dart test                                 # Run unit tests
bash tool/gate.sh                         # Run ALL quality checks
```

See [Testing Guide](docs/contributor/testing.md) for more commands.

## Test Commands

### Dart unit tests
```bash
dart test                                 # All unit tests (VM)
dart test --tags=ffi                      # FFI unit tests only
```

### FFI integration tests (requires built native library)
```bash
# Build native dylib first:
cd native && cargo build --release
cp target/release/libdart_monty.dylib ../assets/

# Run against oracle (requires cargo build --bin oracle):
dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped
```

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

# Run the dart2js fixture test directly (after building):
dart test -p chrome --run-skipped --tags=wasm

# Run the standalone wasm_runner.dart (headless Chrome, no dart test):
# This uses a custom runner that prints FIXTURE_RESULT/FIXTURE_DONE lines.
# See tool/test_wasm.sh for the full pipeline — it compiles wasm_runner.dart
# to JS, serves it, and parses the output from Chrome.
```

### WASM oracle test (compares dart2js output vs directive expectations)
```bash
# wasm_fixture_test.dart — driven by # Return= / # Raise= directives
# (unlike oracle_ffi_test which compares against a Rust oracle binary):
dart test test/integration/wasm_fixture_test.dart -p chrome --run-skipped --tags=wasm
```

### Rust tests and linting
```bash
cd native

# Unit + integration tests:
cargo test

# Clippy linter (zero warnings required):
cargo clippy -- -D warnings

# Format check:
cargo fmt --check
```

### Dart linting
```bash
dart analyze --fatal-infos                # Zero issues required
dcm analyze .                             # DCM rules (zero issues required)
dart format --set-exit-if-changed .       # Format check
```

## Architecture

Pure Dart with compile-time conditional imports (no Flutter required).

- `lib/src/platform/` -- abstract contract (pure Dart); concrete implementations in `dart_monty_core`
- `lib/src/bridge/` -- high-level bridge with extensions and host functions

See [Architecture Overview](docs/architecture/overview.md) for details.

## Development Rules

- Follow KISS, YAGNI, SOLID.
- Match surrounding code style exactly.
- Run `dart format` before committing.
- Keep `lib/src/platform/` pure Dart (no Flutter).
- All JSON keys at the C FFI boundary must be `snake_case`.
- **Dispose:** `MontyFfi` and `MontyNative` must be disposed to avoid leaks.

## Commit Messages

Follow conventional commits: `<type>(<scope>): <description>`.
Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`.
