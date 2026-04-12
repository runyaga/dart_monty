# Agents

Instructions for AI coding agents working on this repository.

## Quick Reference

```bash
dart pub get                              # Install dependencies
dart format .                             # Format all Dart files
dart analyze --fatal-infos                # Analyze (zero issues required)
dart test                                 # Run unit tests
bash tool/gate.sh                         # Run ALL quality checks
```

See [Testing Guide](docs/contributor/testing.md) for more commands.

## Architecture

Pure Dart with compile-time conditional imports (no Flutter required).

- `lib/src/platform/` -- abstract contract (pure Dart)
- `lib/src/ffi/` -- native FFI bindings via `dart:ffi`
- `lib/src/wasm/` -- web WASM bindings via `dart:js_interop`
- `lib/src/bridge/` -- high-level bridge with plugins and host functions

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
