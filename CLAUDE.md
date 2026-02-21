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
cd native && cargo test                   # Run Rust unit + integration tests
cd native && cargo fmt --check            # Check Rust formatting
cd native && cargo clippy -- -D warnings  # Run Rust linter (zero warnings)
bash tool/test_m1.sh                      # Full M1 validation gate
bash tool/test_m2.sh                      # Full M2 validation gate (Rust + WASM)
bash tool/test_m3a.sh                     # Full M3A validation gate (FFI package)
pre-commit run --all-files                # Run all pre-commit hooks
```

## Project Structure

```text
packages/
  dart_monty_platform_interface/  # Platform interface contract (pure Dart)
  dart_monty_ffi/                 # Native FFI impl (desktop + mobile)
  dart_monty_web/                 # Web impl (JS interop with @pydantic/monty)
native/                           # Rust crate: C API wrapper around monty (17 extern "C" fns)
docs/                             # Documentation, ADRs, and API references
  monty-rust-api.md               # Upstream Monty Rust API + C FFI JSON contract
  milestones/                     # Detailed milestone specs (M1-M9)
tool/                             # Developer scripts and gate runners
```

## Architecture

Federated plugin using four packages:

- `dart_monty` — app-facing API
- `dart_monty_platform_interface` — abstract contract (pure Dart, no Flutter)
- `dart_monty_ffi` — calls into Rust shared library via `dart:ffi`
- `dart_monty_web` — calls into `@pydantic/monty` npm package via `dart:js_interop`

## Monty API and JSON Contract

The native Rust FFI layer wraps pydantic's `monty` interpreter (pinned to
git rev `87f8f31`). Two key references:

- **Upstream Rust API:** `docs/monty-rust-api.md` — `MontyRun`, `RunProgress`,
  `MontyObject`, `ResourceTracker`, `PrintWriter`, snapshot/restore
- **C FFI JSON contract:** Defined in the same doc. All JSON uses snake\_case
  keys matching Dart `fromJson` factories exactly

Key JSON shapes (Rust -> Dart):

| Dart type | JSON |
|-----------|------|
| `MontyResult` | `{ "value": ..., "error": {...}?, "usage": {...} }` |
| `MontyException` | `{ "message": "...", "filename"?, "line_number"?, "column_number"?, "source_code"? }` |
| `MontyResourceUsage` | `{ "memory_bytes_used": N, "time_elapsed_ms": N, "stack_depth_used": N }` |

Iterative execution uses C enum return tags (`MontyProgressTag`) plus
accessor functions (`monty_pending_fn_name`, `monty_pending_fn_args_json`,
`monty_complete_result_json`) — Dart constructs `MontyPending`/`MontyComplete`
from these accessors, not from a single JSON blob.

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
4. Maintain 90%+ line coverage (enforced by CI and pre-push hooks)

## Linting

- **Dart**: `dart analyze --fatal-infos` per sub-package (via `tool/analyze_packages.py`)
- **DCM**: `dcm analyze packages` (commercial license required)
- **Markdown**: `pymarkdown scan **/*.md` (Python, not JavaScript markdownlint)
- **Secrets**: `gitleaks detect` (runs in pre-commit and CI)
