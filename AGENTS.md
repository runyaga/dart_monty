# Agents

Instructions for AI coding agents working on this repository.

## Before Writing Code

1. Read this file for project conventions, commands, and architecture.
2. Read `docs/architecture.md` for detailed module structure and execution paths.
3. Read `docs/monty-rust-api.md` for the upstream Monty Rust API and the
   C FFI JSON contract (required for any FFI or bindings work).

## Quick Reference

```bash
dart pub get                              # Install dependencies
dart format .                             # Format all Dart files
dart analyze --fatal-infos                # Analyze (zero issues required)
dart test                                 # Run unit tests
dart test --run-skipped --tags=ladder     # Run ladder integration tests
dart test --run-skipped --tags=integration # Run all integration tests
cd native && cargo build --release        # Build Rust native library
cd native && cargo test                   # Run Rust unit + integration tests
cd native && cargo fmt --check            # Check Rust formatting
cd native && cargo clippy -- -D warnings  # Run Rust linter (zero warnings)
bash tool/gate.sh                         # Run ALL quality checks
bash tool/gate.sh --dart-only             # Skip Rust, WASM, web integration
pre-commit run --all-files                # Run all pre-commit hooks
```

## Project Structure

```text
lib/
  dart_monty.dart              # Public API (platform types + Monty class)
  dart_monty_ffi.dart          # FFI backend exports (MontyFfi, MontyNative)
  dart_monty_wasm.dart         # WASM backend exports (MontyWasm)
  dart_monty_bridge.dart       # Bridge layer exports
  dart_monty_testing.dart      # Test utilities (MockMontyPlatform, ladder)
  monty_backend_spi.dart       # SPI for custom backends
  src/
    monty.dart                 # Monty convenience class
    monty_factory.dart         # Conditional import selector
    platform/                  # Platform interface contract (pure Dart)
    ffi/                       # Native FFI bindings (dart:ffi)
    wasm/                      # WASM bindings (dart:js_interop)
    bridge/                    # High-level bridge (plugins, host functions)
hook/
  build.dart                   # Native assets build hook
native/                        # Rust crate: C API wrapper around monty
test/
  platform/                    # Platform interface tests
  ffi/                         # FFI tests (unit + integration)
  wasm/                        # WASM tests (unit + integration)
  bridge/                      # Bridge tests (unit + integration)
  fixtures/python_ladder/      # Cross-platform parity fixtures
spike/
  web_test/                    # Web spike + browser ladder runner
docs/                          # Documentation, ADRs, and API references
tool/                          # Developer scripts and gate runners
```

## Architecture

Pure Dart with compile-time conditional imports (no Flutter required).
Single package with four internal modules:

- `lib/src/platform/` -- abstract contract (pure Dart)
- `lib/src/ffi/` -- native FFI bindings via `dart:ffi`
- `lib/src/wasm/` -- web WASM bindings via `dart:js_interop`
- `lib/src/bridge/` -- high-level bridge with plugins and host functions

### Barrel Files

- **`dart_monty.dart`** -- public API for application code
- **`dart_monty_ffi.dart`** -- FFI backend types for native consumers
- **`dart_monty_wasm.dart`** -- WASM backend types with conditional exports
- **`dart_monty_bridge.dart`** -- bridge layer types
- **`monty_backend_spi.dart`** -- SPI for backend implementers only
- **`dart_monty_testing.dart`** -- test utilities (MockMontyPlatform, ladder)

**Rules:**
- Backend modules (`ffi/`, `wasm/`) use `monty_backend_spi.dart` for implementation types
- Application code and bridge MUST NOT import `monty_backend_spi.dart`
- `dart:ffi` types are only in `dart_monty_ffi.dart` (never in `dart_monty.dart`)

### Execution Paths

**Native (desktop/mobile):**
`Dart -> lib/src/ffi/ -> dart:ffi -> libdart_monty_native.dylib/so -> Monty Rust`

**Web (browser):**
`Dart -> lib/src/wasm/ -> dart:js_interop -> monty_glue.js -> Web Worker -> Monty WASM`

## Testing

```bash
dart test                                    # Unit tests only (fast)
dart test test/platform/                     # Platform interface tests
dart test test/ffi/                          # FFI unit tests
dart test test/wasm/                         # WASM unit tests
dart test test/bridge/                       # Bridge unit tests
dart test --run-skipped --tags=ladder        # Python ladder fixtures
dart test --run-skipped --tags=integration   # All integration tests
```

Integration and ladder tests are **skipped by default** via `dart_test.yaml`.

## Validation Workflow

Run these commands from the repository root after every change:

```bash
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

Do not commit unless all three pass with zero errors.

## Linting Tools

| Tool | Command | Scope |
|------|---------|-------|
| Dart analyzer | `dart analyze --fatal-infos` | All Dart code |
| DCM | `dcm analyze lib` | lib/ (blocking) |
| DCM unused code | `dcm check-unused-code lib` | lib/ (blocking) |
| DCM unused files | `dcm check-unused-files lib` | lib/ (blocking) |
| DCM dependencies | `dcm check-dependencies .` | Root (blocking) |
| Rust fmt | `cd native && cargo fmt --check` | `native/` |
| Rust clippy | `cd native && cargo clippy -- -D warnings` | `native/` |
| Markdown | `pymarkdown scan docs/*.md` | docs/ |
| Secrets | `gitleaks detect` | Entire repo |

## Development Rules

- Follow KISS, YAGNI, SOLID
- Edit existing files; avoid creating new ones without need
- Match surrounding code style exactly
- Keep `lib/src/platform/` pure Dart (no Flutter imports)
- Never add `// ignore:` directives to suppress analyzer warnings

## Commit Messages

Follow conventional commits with scope:

```text
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

## Releasing

Single package publishes to pub.dev via OIDC trusted publishers (tag-triggered CI).
The `v<version>` tag triggers both pub.dev publish AND native/web binary release.

## Architecture Constraints

- Keep `lib/src/platform/` as pure Dart (no Flutter SDK imports).
- Never add `// ignore:` directives to suppress analyzer warnings.
- Run `dart format` before committing; the CI enforces `--set-exit-if-changed`.
- All JSON at the C FFI boundary must use snake\_case keys matching Dart
  `fromJson` factories -- see `docs/monty-rust-api.md` for the contract.
