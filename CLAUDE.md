# dart_monty

Pure Dart bindings for the Monty sandboxed Python interpreter.

## Quick Reference

```bash
dart pub get                              # Install root dependencies
dart format .                             # Format all Dart files
python3 tool/analyze_packages.py          # Analyze all sub-packages
dart test                                 # Run unit tests (from package dir)
dart test --run-skipped --tags=ladder     # Run ladder integration tests (FFI pkg)
dart test --run-skipped --tags=integration # Run all integration tests (FFI pkg)
dart test --coverage=coverage             # Run tests with coverage
cd native && cargo build --release        # Build Rust native library
cd native && cargo test                   # Run Rust unit + integration tests
cd native && cargo fmt --check            # Check Rust formatting
cd native && cargo clippy -- -D warnings  # Run Rust linter (zero warnings)
bash tool/test_platform_interface.sh       # Platform interface gate
bash tool/test_rust.sh                    # Rust native crate gate (+ WASM)
bash tool/test_ffi.sh                     # FFI package gate
bash tool/test_python_ladder.sh           # M3C: Python ladder on native + web
bash tool/test_cross_path_parity.sh       # M3C: JSONL parity diff (native vs web)
bash tool/test_snapshot_portability.sh    # M3C: Snapshot portability probe
pre-commit run --all-files                # Run all pre-commit hooks
```

## Project Structure

```text
packages/
  dart_monty_platform_interface/  # Platform interface contract (pure Dart)
  dart_monty_ffi/                 # Native FFI impl (desktop + mobile)
  dart_monty_web/                 # Web impl (JS interop with @pydantic/monty)
native/                           # Rust crate: C API wrapper around monty (17 extern "C" fns)
spike/
  web_test/                       # M3B web spike + M3C web ladder runner
    bin/                          # Dart entry points (main.dart, ladder_runner.dart)
    web/                          # HTML, JS glue/worker, bundled assets
test/
  fixtures/
    python_ladder/                # Cross-platform parity fixtures (M3C)
docs/                             # Documentation, ADRs, and API references
  monty-rust-api.md               # Upstream Monty Rust API + C FFI JSON contract
  architecture.md                 # Detailed architecture documentation
tool/                             # Developer scripts and gate runners
```

## Architecture

Pure Dart with compile-time conditional imports (no Flutter required). Four packages:

- `dart_monty` — app-facing API (`Monty()` convenience class, conditional imports)
- `dart_monty_platform_interface` — abstract contract (pure Dart)
- `dart_monty_ffi` — native FFI bindings via `dart:ffi`
- `dart_monty_wasm` — web WASM bindings via `dart:js_interop`

### SPI Contract

`dart_monty_platform_interface` has two barrel exports:

- **`dart_monty_platform_interface.dart`** — public API for application code (`MontyPlatform`, `MontyResult`, `MontyError`, etc.)
- **`monty_backend_spi.dart`** — SPI for backend implementers only (`BaseMontyPlatform`, `MontyCoreBindings`, `MontyStateMixin`)

**Rules:**
- Backend packages (`dart_monty_ffi`, `dart_monty_wasm`) MUST import `monty_backend_spi.dart` for implementation types
- Application code and `dart_monty_bridge` MUST NOT import `monty_backend_spi.dart`
- Never re-export SPI types through the main `dart_monty_platform_interface.dart` barrel

### Execution Paths

**Native (desktop/mobile):**
`Dart → dart_monty_ffi → dart:ffi → libdart_monty_native.dylib/so → Monty Rust`

**Web (browser):**
`Dart → dart:js_interop → monty_glue.js → Web Worker → @pydantic/monty WASM`

The web path uses a Worker because Chrome's 8 MB synchronous WASM compile
limit does not apply inside Workers. `monty_glue.js` bridges main thread
Dart code to the Worker via `postMessage`. The Worker imports
`@pydantic/monty-wasm32-wasi` NAPI-RS classes directly.

### Cross-Platform Parity (M3C)

Both paths are verified to produce identical results via JSON test
fixtures in `test/fixtures/python_ladder/` (expressions, variables,
control flow, functions, errors, external functions). A native Dart test
runner and a web Dart-to-JS runner execute the same fixtures; JSONL output
is diffed for parity.

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
| `MontyResult` | `{ "value": ..., "error": {...}?, "usage": {...}, "print_output": "..."? }` |
| `MontyException` | `{ "message": "...", "filename"?, "line_number"?, "column_number"?, "source_code"? }` |
| `MontyResourceUsage` | `{ "memory_bytes_used": N, "time_elapsed_ms": N, "stack_depth_used": N }` |

Iterative execution uses C enum return tags (`MontyProgressTag`) plus
accessor functions (`monty_pending_fn_name`, `monty_pending_fn_args_json`,
`monty_complete_result_json`) — Dart constructs `MontyPending`/`MontyComplete`
from these accessors, not from a single JSON blob.

## Upstream Monty Module System

Python stdlib modules are implemented in the upstream monty Rust source at:
`crates/monty/src/modules/` (in the `pydantic/monty` or `runyaga/monty` repo)

The `StandardLib` enum in `crates/monty/src/modules/mod.rs` registers all
available modules. As of monty main branch: `sys`, `typing`, `asyncio`,
`pathlib`, `os`, `math`, `json`, `re`, `datetime`.

**dart\_monty is pinned** to the fork branch (`runyaga/0.0.8`). Not all
upstream modules may be available in the pinned version. Check the ladder
test fixtures (`test/fixtures/python_ladder/`) for which modules have
passing tests vs `xfail` markers.

When updating monty versions, check `crates/monty/src/modules/mod.rs` in
the new version to see which modules were added or changed, then update
the ladder fixtures accordingly.

## Testing

The FFI package uses Dart's native assets system (`hook/build.dart`) to
auto-build or download the native library. `dart run` triggers the hook
automatically. `dart test` also triggers the hook, but integration and
ladder tests are **skipped by default** via `dart_test.yaml` to keep
`dart test` fast.

**Running integration tests** (from `packages/dart_monty_ffi`):

```bash
dart test --run-skipped --tags=ladder        # Python ladder fixtures only
dart test --run-skipped --tags=integration   # All integration tests
dart test --run-skipped                      # Everything including integration
```

`DYLD_LIBRARY_PATH` is NOT needed — the build hook resolves the native
library automatically. The `--run-skipped` flag overrides the
`dart_test.yaml` skip that keeps integration tests out of the default
`dart test` run.

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
4. Maintain 70%+ line coverage (enforced by CI and pre-push hooks)

## Pre-Commit/Push CI Gates

**Before every commit and push**, run the full local CI pipeline:

```bash
bash tool/gate.sh                              # Run ALL quality checks
bash tool/gate.sh --dart-only                  # Skip Rust, WASM, web integration
bash tool/test_platform_interface.sh           # Platform interface only
bash tool/test_rust.sh                         # Rust crate only (skip if no cargo)
bash tool/test_ffi.sh                          # FFI package only
bash tool/test_python_ladder.sh                # Python ladder parity
```

Run `tool/gate.sh` for the full pipeline. Gates that fail due to missing
toolchains (e.g. `cargo` not installed, WASM cpu mismatch) are acceptable
skips — but Dart gates must pass. Do not commit or push if any Dart gate
fails.

## Releasing

Packages publish to pub.dev via OIDC trusted publishers (tag-triggered CI).
The `v<version>` tag triggers both pub.dev publish AND native/web binary release.

**Publish order** (dependency chain):
`struct_log` → `platform_interface` → `ffi` / `wasm` / `bridge` → `web` / `native` → `dart_monty`

**Tag patterns:**
- `platform_interface-v<ver>`, `ffi-v<ver>`, `wasm-v<ver>`, `bridge-v<ver>`, `web-v<ver>`, `native-v<ver>` → pub.dev only
- `v<ver>` → pub.dev + GitHub Release (native binaries + web bundle)
- `monty_cli` is NOT published to pub.dev

See `CONTRIBUTING.md` for the complete release process, including:
- Pre-release checklist
- Tagging and publishing in dependency order
- Post-release verification and cleanup
- Troubleshooting failed publishes

## PR Labels for Changelogs

When creating PRs, add a label matching the conventional commit type so
GitHub auto-generated release notes are categorized correctly:

| PR title prefix | Label to apply |
|-----------------|---------------|
| `feat(…):` | `feat` |
| `fix(…):` | `fix` |
| `refactor(…):` | `refactor` |
| `docs(…):` | `docs` |
| `test(…):` | `test` |
| `chore(…):` | `chore` |

Config: `.github/release.yml`

## Linting

- **Dart**: `dart analyze --fatal-infos` per sub-package (via `tool/analyze_packages.py`)
- **DCM**: `dcm analyze packages` (commercial license required)
- **Markdown**: `pymarkdown scan **/*.md` (Python, not JavaScript markdownlint)
- **Secrets**: `gitleaks detect` (runs in pre-commit and CI)
