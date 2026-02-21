# dart_monty

Flutter plugin exposing the Monty sandboxed Python interpreter to Dart/Flutter.

## Quick Reference

```bash
flutter pub get                           # Install root dependencies
dart format .                             # Format all Dart files
python3 tool/analyze_packages.py          # Analyze all sub-packages
dart test                                 # Run tests (from package dir)
dart test --coverage=coverage             # Run tests with coverage
cd native && cargo build --release        # Build Rust native library
pre-commit run --all-files                # Run all pre-commit hooks
```

## Project Structure

```text
packages/
  dart_monty_platform_interface/  # Platform interface contract (pure Dart)
  dart_monty_ffi/                 # Native FFI impl (desktop + mobile)
  dart_monty_web/                 # Web impl (JS interop with @pydantic/monty)
native/                           # Rust crate: C API wrapper around monty
docs/                             # Documentation and ADRs
tool/                             # Developer scripts
```

## Architecture

Federated plugin using four packages:

- `dart_monty` — app-facing API
- `dart_monty_platform_interface` — abstract contract (pure Dart, no Flutter)
- `dart_monty_ffi` — calls into Rust shared library via `dart:ffi`
- `dart_monty_web` — calls into `@pydantic/monty` npm package via `dart:js_interop`

## Development Rules

- Follow KISS, YAGNI, SOLID
- Edit existing files; avoid creating new ones without need
- Match surrounding code style exactly
- Keep `platform_interface` pure Dart (no Flutter imports)
- Never add `// ignore:` directives

## Code Quality

Run these checks after every code change:

1. `dart format .` — must produce no changes
2. `python3 tool/analyze_packages.py` — must report zero issues
3. `dart test` (from package dir) — must pass all tests
4. Maintain 85%+ line coverage

## Linting

- **Dart**: `dart analyze --fatal-infos` per sub-package (via `tool/analyze_packages.py`)
- **DCM**: `dcm analyze packages` (commercial license required)
- **Markdown**: `pymarkdown scan **/*.md` (Python, not JavaScript markdownlint)
- **Secrets**: `gitleaks detect` (runs in pre-commit and CI)
