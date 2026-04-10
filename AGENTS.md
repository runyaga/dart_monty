# Agents

Instructions for AI coding agents working on this repository.

## Before Writing Code

1. Read this file for project conventions, commands, and architecture.
2. Read `docs/architecture.md` for detailed module structure and execution paths.
3. Read `docs/monty-rust-api.md` for the upstream Monty Rust API and the
   C FFI JSON contract (required for any FFI or bindings work).

**SDK version parity:** Your local Dart SDK MUST match CI (`sdk: stable`).
Run `dart --version` and compare with the CI logs. Format and analysis
differences between SDK versions cause CI failures. Upgrade with
`flutter upgrade` (Dart ships inside Flutter) before committing.

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

### Unit Tests (VM)

```bash
dart test                                    # All unit tests (fast)
dart test test/platform/                     # Platform interface tests
dart test test/ffi/                          # FFI unit tests
dart test test/wasm/                         # WASM unit tests (VM-only, no browser)
dart test test/bridge/                       # Bridge unit tests
```

### FFI Integration Tests (Native)

The FFI module uses Dart's native assets system (`hook/build.dart`) to
auto-build or download the native library. `dart test` triggers the hook
automatically. Integration and ladder tests are **skipped by default** via
`dart_test.yaml` to keep `dart test` fast.

```bash
dart test --run-skipped --tags=ladder         # Python ladder fixtures only
dart test --run-skipped --tags=integration    # All integration tests
dart test --run-skipped                       # Everything including integration
```

`DYLD_LIBRARY_PATH` is NOT needed -- the build hook resolves the native
library automatically. The `--run-skipped` flag overrides the skip.

### WASM Integration Tests (Browser)

WASM integration tests (`test/wasm/integration/`) are **standalone
executables** compiled to JS, not `package:test` files. They run in
headless Chrome with COOP/COEP headers and are NOT included in `dart test`.

The automated gate runs them via:

```bash
bash tool/test_python_ladder.sh    # Builds, serves, runs in headless Chrome
```

To build and run manually:

```bash
# 1. Compile the ladder runner to JS
dart compile js test/wasm/integration/python_ladder_runner.dart \
  -o test/wasm/integration/web/ladder_runner.dart.js

# 2. Compile the smoke test to JS
dart compile js test/wasm/integration/smoke_runner.dart \
  -o test/wasm/integration/web/smoke_test.dart.js

# 3. Copy WASM assets into the integration web dir
cp assets/dart_monty_bridge.js test/wasm/integration/web/
cp assets/dart_monty_worker.js test/wasm/integration/web/
cp assets/*.wasm test/wasm/integration/web/

# 4. Copy fixtures
mkdir -p test/wasm/integration/web/fixtures
cp test/fixtures/python_ladder/tier_*.json test/wasm/integration/web/fixtures/
```

Then serve with COOP/COEP headers (see "Manual Browser Testing" below).

### Cross-Platform Parity

Both the native FFI and web WASM paths are verified to produce identical
results via JSON test fixtures in `test/fixtures/python_ladder/`. The
`tool/test_cross_path_parity.sh` script runs both runners and diffs their
JSONL output.

### Web Spike (spike/web\_test)

The web spike at `spike/web_test/` uses npm + esbuild to bundle the Monty
WASM glue for the browser. This produces `monty_bundle.js` and
`monty_worker.js` which are required by the HTML pages.

```bash
cd spike/web_test
npm install --force          # --force needed: wasm32 cpu mismatch on host
npm run bundle               # esbuild: monty_bundle.js + monty_worker.js
dart pub get
dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js
```

Or run the full automated pipeline:

```bash
bash tool/test_python_ladder.sh    # Builds everything, runs headless Chrome
bash tool/test_web_spike.sh        # Web spike only
```

### Manual Browser Testing

To test in a real browser (not headless), you need a local server with
COOP/COEP headers (required for SharedArrayBuffer / WASM threading).

**For the web spike:**

```bash
cd spike/web_test

# One-time: set up symlinks for WASM binary and fixtures
cd web
ln -s ../../../test/fixtures/python_ladder fixtures
ln -sf ../node_modules/@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm \
  monty.wasm32-wasi.wasm
mkdir -p "@pydantic/monty-wasm32-wasi"
ln -sf ../../../node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
  "@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"
ln -sf ../../../node_modules/@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm \
  "@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm"
cd ..

# Start the COOP/COEP server
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
```

Then open in your browser:

- `http://127.0.0.1:8099/index.html` -- smoke test
- `http://127.0.0.1:8099/ladder_runner.html` -- full ladder runner

**Why symlinks are needed:** esbuild bundles the JS glue but marks `*.wasm`
as external. The bundled `monty_worker.js` resolves the WASM binary and
WASI sub-worker via `new URL(..., import.meta.url)` relative to its own
server path. Without symlinks the server returns 404s, causing
`WebAssembly.Module(): expected magic word 00 61 73 6d` errors.

**For the examples (`example/web/`, `example/web-showcase/`):**

These are standalone HTML+JS apps that don't use `package:test`. Serve
their directories with the same COOP/COEP Python server above, adjusting
the `directory=` argument.

### Gate Scripts

```bash
bash tool/gate.sh                        # Run ALL quality checks (preferred)
bash tool/gate.sh --dart-only            # Skip Rust, WASM, web integration
bash tool/test_python_ladder.sh          # Python ladder (native + web)
bash tool/test_cross_path_parity.sh      # JSONL parity diff (native vs web)
bash tool/test_snapshot_portability.sh   # Snapshot portability probe
```

## WASM Architecture

The WASM backend (`lib/src/wasm/`) provides browser support via a direct
`wasm32-wasip1` C ABI -- bypassing NAPI-RS entirely for a 4.5 MB binary.

```text
Dart (lib/src/wasm/)
  -> dart:js_interop
    -> monty_glue.js (spike/web_test/web/)
      -> Web Worker (monty_worker_src.js)
        -> Monty WASM binary (wasm32-wasip1)
```

The Worker is required because Chrome's 8 MB synchronous WASM compile
limit does not apply inside Workers. `monty_glue.js` bridges main-thread
Dart to the Worker via `postMessage`.

### WASM Build

The WASM binary is built from the same Rust `native/` crate:

```bash
cd native && cargo build --release --target wasm32-wasip1
```

Requires: `rustup target add wasm32-wasip1`

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
