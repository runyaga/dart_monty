# dart_monty

Flutter plugin exposing the Monty sandboxed Python interpreter to Dart/Flutter.

## Quick Reference

```bash
flutter pub get                           # Install dependencies
flutter test                              # Run tests
flutter test --coverage                   # Run tests with coverage
dart format .                             # Format code
flutter analyze --fatal-infos             # Analyze (must be 0 issues)
cd native && cargo build --release        # Build native Rust library
npx markdownlint-cli "<file>"            # Lint markdown
```

## Project Structure

```text
lib/src/             # Top-level plugin API (DartMonty class)
packages/
  dart_monty_platform_interface/  # Platform interface contract
  dart_monty_ffi/                 # Native FFI impl (desktop + mobile)
  dart_monty_web/                 # Web impl (JS interop with @pydantic/monty)
native/                           # Rust crate: C API wrapper around monty
docs/                             # Documentation and ADRs
tool/                             # Developer scripts
```

## Architecture

Federated plugin pattern:

- `dart_monty` - app-facing API
- `dart_monty_platform_interface` - abstract contract
- `dart_monty_ffi` - `dart:ffi` calls into Rust->C shared library
- `dart_monty_web` - `dart:js_interop` calls into `@pydantic/monty` npm package

## Development Rules

- KISS, YAGNI, SOLID
- Edit existing files; do not create new ones without need
- Match surrounding code style exactly
- Keep platform_interface pure Dart (no Flutter imports)
- Never use `// ignore:` directives

## Code Quality

After any code modification, run in order:

1. `dart format .` (must produce no changes)
2. `flutter analyze --fatal-infos` (must be 0 errors, warnings, and hints)
3. `flutter test` (must pass)
4. Coverage target: 85%+
