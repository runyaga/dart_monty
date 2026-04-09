# Agents

Instructions for AI coding agents working on this repository.

## Before Writing Code

1. Read this file for project conventions, commands, and architecture.
2. Read `docs/architecture.md` for detailed package structure and execution paths.
3. Read `docs/monty-rust-api.md` for the upstream Monty Rust API and the
   C FFI JSON contract (required for any FFI or bindings work).

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
  dart_monty_wasm/                # WASM backend (wasm32-wasip1 direct C ABI)
  dart_monty_web/                 # Web impl (JS interop with @pydantic/monty)
  dart_monty_bridge/              # High-level bridge (plugins, host functions)
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

- `dart_monty` -- app-facing API (`Monty()` convenience class, conditional imports)
- `dart_monty_platform_interface` -- abstract contract (pure Dart)
- `dart_monty_ffi` -- native FFI bindings via `dart:ffi`
- `dart_monty_wasm` -- web WASM bindings via `dart:js_interop`

### SPI Contract

`dart_monty_platform_interface` has two barrel exports:

- **`dart_monty_platform_interface.dart`** -- public API for application code (`MontyPlatform`, `MontyResult`, `MontyError`, etc.)
- **`monty_backend_spi.dart`** -- SPI for backend implementers only (`BaseMontyPlatform`, `MontyCoreBindings`, `MontyStateMixin`)

**Rules:**
- Backend packages (`dart_monty_ffi`, `dart_monty_wasm`) MUST import `monty_backend_spi.dart` for implementation types
- Application code and `dart_monty_bridge` MUST NOT import `monty_backend_spi.dart`
- Never re-export SPI types through the main `dart_monty_platform_interface.dart` barrel

### Execution Paths

**Native (desktop/mobile):**
`Dart -> dart_monty_ffi -> dart:ffi -> libdart_monty_native.dylib/so -> Monty Rust`

**Web (browser):**
`Dart -> dart_monty_wasm -> dart:js_interop -> monty_glue.js -> Web Worker -> Monty WASM`

The web path uses a Worker because Chrome's 8 MB synchronous WASM compile
limit does not apply inside Workers. `monty_glue.js` bridges main thread
Dart code to the Worker via `postMessage`. The Worker imports
the Monty WASM binary directly.

### Cross-Platform Parity (M3C)

Both paths are verified to produce identical results via JSON test
fixtures in `test/fixtures/python_ladder/` (expressions, variables,
control flow, functions, errors, external functions). A native Dart test
runner and a web Dart-to-JS runner execute the same fixtures; JSONL output
is diffed for parity.

## Monty API and JSON Contract

The native Rust FFI layer wraps pydantic's `monty` interpreter. Two key references:

- **Upstream Rust API:** `docs/monty-rust-api.md` -- `MontyRun`, `RunProgress`,
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
`monty_complete_result_json`) -- Dart constructs `MontyPending`/`MontyComplete`
from these accessors, not from a single JSON blob.

## Upstream Monty Module System

Python stdlib modules are implemented in the upstream monty Rust source at:
`crates/monty/src/modules/` (in the `pydantic/monty` or `runyaga/monty` repo)

The `StandardLib` enum in `crates/monty/src/modules/mod.rs` registers all
available modules. As of monty main branch: `sys`, `typing`, `asyncio`,
`pathlib`, `os`, `math`, `json`, `re`, `datetime`.

**dart\_monty is pinned** to the fork branch (`runyaga/0.0.10`). Not all
upstream modules may be available in the pinned version. Check the ladder
test fixtures (`test/fixtures/python_ladder/`) for which modules have
passing tests vs `xfail` markers.

When updating monty versions, check `crates/monty/src/modules/mod.rs` in
the new version to see which modules were added or changed, then update
the ladder fixtures accordingly.

## WASM Backend

The WASM backend (`dart_monty_wasm`) provides browser support via a direct
`wasm32-wasip1` C ABI -- bypassing NAPI-RS entirely for a 4.5 MB binary
(vs 256 MB NAPI-RS overhead).

### WASM Architecture

```text
Dart (dart_monty_wasm)
  -> dart:js_interop
    -> monty_glue.js (spike/web_test/web/)
      -> Web Worker (monty_worker_src.js)
        -> Monty WASM binary (wasm32-wasip1)
```

- **`monty_glue.js`** -- bridges main-thread Dart to the Worker via `postMessage`
- **`monty_worker_src.js`** -- runs inside a Web Worker, loads and calls the WASM binary
- The Worker is required because Chrome's 8 MB synchronous WASM compile limit
  does not apply inside Workers

### WASM Package Structure

```text
packages/dart_monty_wasm/
  lib/src/
    monty_wasm.dart              # MontyWasm class (platform registration)
    wasm_bindings.dart           # Conditional import stub selection
    wasm_bindings_js.dart        # JS interop bindings (dart:js_interop)
    wasm_bindings_js_stub.dart   # Stub for non-web platforms
    wasm_core_bindings.dart      # WasmCoreBindings (MontyCoreBindings impl)
  js/
    src/                         # JS source for the WASM bridge
    build.js                     # Build script for JS bundle
    package.json                 # npm dependencies
  assets/                        # Bundled WASM binary (built by CI)
  test/
    monty_wasm_test.dart         # Unit tests (always run)
    wasm_core_bindings_test.dart # Core bindings unit tests (always run)
    integration/
      smoke_test.dart            # Browser integration smoke test
      python_ladder_test.dart    # Full ladder test suite (browser)
      cancel_benchmark.dart      # Cancel performance benchmark
```

### WASM Testing

Unit tests run without a browser:
```bash
cd packages/dart_monty_wasm && dart test
```

Integration tests require Chrome (or headless Chrome):
```bash
cd packages/dart_monty_wasm && dart test --run-skipped --tags=integration -p chrome
```

The `dart_test.yaml` in the WASM package restricts default test runs to
unit tests only. Use `--run-skipped` for integration tests.

### WASM Build

The WASM binary is built from the same Rust `native/` crate, targeting
`wasm32-wasip1`:

```bash
cd native && cargo build --release --target wasm32-wasip1
```

Requires the WASM target: `rustup target add wasm32-wasip1`

The JS bridge is built via npm:
```bash
cd packages/dart_monty_wasm/js && npm install && node build.js
```

### Web Spike / Browser Ladder (spike/web_test)

The web spike uses npm + esbuild to bundle the Monty WASM glue for the
browser. This produces `monty_bundle.js` and `monty_worker.js` which are
required by the HTML pages.

```bash
cd spike/web_test
npm install --force          # --force needed: wasm32 cpu mismatch on host
npm run bundle               # esbuild: monty_bundle.js + monty_worker.js
dart pub get
dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js
```

Serve with COOP/COEP headers (required for SharedArrayBuffer):
```bash
bash tool/test_web_spike.sh  # full automated build + headless Chrome verify
```

Or for interactive browser testing, first set up symlinks (one-time):

```bash
cd spike/web_test/web

# Fixtures — the ladder runner fetches from fixtures/ relative to the server
ln -s ../../../test/fixtures/python_ladder fixtures

# WASM binary — the bundled worker loads monty.wasm32-wasi.wasm via import.meta.url
ln -sf ../node_modules/@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm monty.wasm32-wasi.wasm

# WASI sub-worker — the worker spawns a sub-worker from this path
mkdir -p "@pydantic/monty-wasm32-wasi"
ln -sf ../../../node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
  "@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"
ln -sf ../../../node_modules/@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm \
  "@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm"
```

Then start a server with COOP/COEP headers (required for SharedArrayBuffer):

```bash
cd spike/web_test
python3 -c "
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def guess_type(self, path):
        if path.endswith('.mjs'): return 'application/javascript'
        if path.endswith('.wasm'): return 'application/wasm'
        return super().guess_type(path)
handler = functools.partial(H, directory='web')
http.server.HTTPServer(('127.0.0.1', 8099), handler).serve_forever()
"
# Open http://127.0.0.1:8099/ladder_runner.html
```

**Why symlinks are needed:** esbuild bundles the JS glue but marks `*.wasm`
as external. The bundled `monty_worker.js` resolves the WASM binary and
WASI sub-worker via `new URL(..., import.meta.url)` relative to its own
server path. Without symlinks the server returns HTML 404 pages, causing
`WebAssembly.Module(): expected magic word 00 61 73 6d` errors.

## Testing

### FFI Tests (Native)

The FFI package uses Dart's native assets system (`hook/build.dart`) to
auto-build or download the native library. `dart run` triggers the hook
automatically. `dart test` also triggers the hook, but integration and
ladder tests are **skipped by default** via `dart_test.yaml` to keep
`dart test` fast.

```bash
cd packages/dart_monty_ffi
dart test                                    # Unit tests only (fast)
dart test --run-skipped --tags=ladder        # Python ladder fixtures only
dart test --run-skipped --tags=integration   # All integration tests
dart test --run-skipped                      # Everything including integration
```

`DYLD_LIBRARY_PATH` is NOT needed -- the build hook resolves the native
library automatically. The `--run-skipped` flag overrides the
`dart_test.yaml` skip that keeps integration tests out of the default
`dart test` run.

The FFI ladder uses `package:test` with `registerLadderTests()` from the
shared test harness in `dart_monty_platform_interface`. Fixtures live in
`test/fixtures/python_ladder/`.

### WASM Tests (Web)

The WASM package has unit tests that run without a browser, and integration
tests that require headless Chrome.

```bash
cd packages/dart_monty_wasm
dart test                                    # Unit tests only (no browser)
```

WASM integration tests (ladder + smoke) are **standalone executables**
compiled to JS, not standard `package:test` files. They run in headless
Chrome with COOP/COEP headers:

```bash
# Build the JS runner
dart compile js test/integration/python_ladder_test.dart \
  -o test/integration/web/ladder_runner.dart.js

# Build the smoke test
dart compile js test/integration/smoke_test.dart \
  -o test/integration/web/smoke_test.dart.js
```

The WASM ladder runner uses `dart:js_interop` to call `DartMontyBridge`
methods directly in the browser, whereas the FFI ladder uses native
`dart:ffi` bindings. Both consume the same JSON fixtures from
`test/fixtures/python_ladder/` and produce JSONL output for parity diffing.

### Spike Web Ladder Runner

A separate web ladder runner lives in `spike/web_test/` for manual browser
testing and the M3C cross-path parity check:

```bash
cd spike/web_test
dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js
```

### Cross-Platform Parity

The `tool/test_cross_path_parity.sh` script runs both the native and web
ladder runners and diffs their JSONL output to verify identical behavior.

## Validation Workflow

Run these commands from the repository root after every change:

```bash
dart format --set-exit-if-changed .
python3 tool/analyze_packages.py
cd packages/<package_name> && dart test
```

Do not commit unless all three pass with zero errors.

For Rust changes in `native/`, also run:

```bash
cd native
cargo fmt --check
cargo clippy -- -D warnings
cargo test
```

### Milestone Gate Scripts

Prefer using the milestone gate scripts -- they run all checks for that
milestone in one shot:

```bash
bash tool/gate.sh                        # Run ALL quality checks (preferred)
bash tool/test_platform_interface.sh     # Platform interface: format + analyze + test + coverage
bash tool/test_rust.sh                   # Rust: fmt + clippy + test + tarpaulin + WASM build
bash tool/test_ffi.sh                    # FFI package (unit + integration)
bash tool/test_python_ladder.sh          # Python ladder (all backends)
bash tool/test_cross_path_parity.sh      # JSONL parity diff (native vs web)
```

Run `tool/gate.sh` for the full pipeline. Gates that fail due to missing
toolchains (e.g. `cargo` not installed, WASM target not added) are acceptable
skips -- but Dart gates must pass. Do not commit or push if any Dart gate
fails.

## Development Rules

- Follow KISS, YAGNI, SOLID
- Edit existing files; avoid creating new ones without need
- Match surrounding code style exactly
- Keep `platform_interface` pure Dart (no Flutter imports)
- Never add `// ignore:` directives

## Code Quality

Run these checks after every code change:

1. `dart format .` -- must produce no changes
2. `python3 tool/analyze_packages.py` -- must report zero issues
3. `dart test` (from package dir) -- must pass all tests
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

## Package-Level Development

Each sub-package resolves its own dependencies. Always run `dart pub get`
inside the target package directory before running tests or analysis.

```bash
cd packages/dart_monty_platform_interface
dart pub get
dart test
```

## Releasing

Packages publish to pub.dev via OIDC trusted publishers (tag-triggered CI).
The `v<version>` tag triggers both pub.dev publish AND native/web binary release.

**Publish order** (dependency chain):
`struct_log` -> `platform_interface` -> `ffi` / `wasm` / `bridge` -> `web` / `native` -> `dart_monty`

**Tag patterns:**
- `platform_interface-v<ver>`, `ffi-v<ver>`, `wasm-v<ver>`, `bridge-v<ver>`, `web-v<ver>`, `native-v<ver>` -> pub.dev only
- `v<ver>` -> pub.dev + GitHub Release (native binaries + web bundle)
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
| `feat(...):`    | `feat`        |
| `fix(...):`     | `fix`         |
| `refactor(...):` | `refactor`  |
| `docs(...):`    | `docs`        |
| `test(...):`    | `test`        |
| `chore(...):`   | `chore`       |

Config: `.github/release.yml`

## Commit Messages

Follow conventional commits with scope:

```text
<type>(<scope>): <description>
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

## Linting Tools

| Tool | Command | Scope |
|------|---------|-------|
| Dart analyzer | `python3 tool/analyze_packages.py` | All sub-packages |
| DCM | `dcm analyze packages` | All sub-packages |
| Rust fmt | `cd native && cargo fmt --check` | `native/` |
| Rust clippy | `cd native && cargo clippy -- -D warnings` | `native/` |
| Rust tests | `cd native && cargo test` | `native/` |
| Markdown | `pymarkdown scan **/*.md` | All `.md` files |
| Secrets | `gitleaks detect` | Entire repo |

Use `pymarkdown` (Python) for markdown linting. Do not use `markdownlint-cli` (JavaScript/npx).

## Architecture Constraints

- Keep `dart_monty_platform_interface` as pure Dart (no Flutter SDK imports).
- Never add `// ignore:` directives to suppress analyzer warnings.
- Resolve warnings by fixing the underlying issue.
- Run `dart format` before committing; the CI enforces `--set-exit-if-changed`.
- All JSON at the C FFI boundary must use snake\_case keys matching Dart
  `fromJson` factories -- see `docs/monty-rust-api.md` for the contract.
- Maintain 70%+ line coverage for both Dart and Rust code.
