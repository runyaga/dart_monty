# Contributing to dart_monty

## Prerequisites

- Dart SDK >= 3.5.0
- Flutter SDK >= 3.24.0
- Rust stable (for native builds)
- Node.js >= 20 (for WASM JS bridge)
- Python 3.12+ (for tooling scripts)

## Quick Start

```bash
flutter pub get
dart format .
python3 tool/analyze_packages.py
cd packages/dart_monty_platform_interface && dart test
```

## Running Examples

### Native (desktop)

Runs Python from Dart via FFI into the Rust native library.

```bash
bash example/native/run.sh
```

### Web (browser)

Runs Python from Dart compiled to JS, via a Web Worker hosting the WASM
interpreter.

```bash
bash example/web/run.sh
```

<details>
<summary>Manual steps (without run scripts)</summary>

**Native:**

```bash
cd native && cargo build --release && cd ..
cd example/native && dart pub get
DART_MONTY_LIB_PATH=../../native/target/release/libdart_monty_native.dylib \
  dart run bin/main.dart
```

**Web:**

```bash
cd packages/dart_monty_wasm/js && npm install && npm run build && cd ../../..
cd example/web && dart pub get
dart compile js bin/main.dart -o web/main.dart.js
cp ../../packages/dart_monty_wasm/assets/dart_monty_bridge.js web/
cp ../../packages/dart_monty_wasm/assets/dart_monty_worker.js web/
cp ../../packages/dart_monty_wasm/assets/wasi-worker-browser.mjs web/
cp ../../packages/dart_monty_wasm/assets/*.wasm web/

# Serve with COOP/COEP headers (required for SharedArrayBuffer)
python3 -c "
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
handler = functools.partial(H, directory='web')
http.server.HTTPServer(('127.0.0.1', 8088), handler).serve_forever()
"
# Open http://localhost:8088/index.html
```

</details>

## Gate Scripts

```bash
bash tool/test_m1.sh          # M1: platform interface
bash tool/test_m2.sh          # M2: Rust + WASM
bash tool/test_m3a.sh         # M3A: FFI package
bash tool/test_wasm.sh        # M4: WASM package (unit + Chrome integration)
bash tool/test_python_ladder.sh       # Python ladder (all backends)
bash tool/test_cross_path_parity.sh   # JSONL parity diff
```

## Code Quality

Run these checks after every code change:

1. `dart format .` — must produce no changes
2. `python3 tool/analyze_packages.py` — must report zero issues
3. `dart test` (from package dir) — must pass all tests
4. Maintain 90%+ line coverage (enforced by CI and pre-push hooks)

## CI

GitHub Actions run on every push and PR to `main`:

- **Lint** — format + ffigen + analyze all sub-packages
- **Test** — per-package with 90% coverage gate (platform_interface, ffi, wasm)
- **Rust** — fmt + clippy + test + tarpaulin coverage (90% gate)
- **Build WASM** — `cargo build --target wasm32-wasip1-threads`
- **Build JS wrapper** — npm install + esbuild bridge/worker
- **Build native** — Ubuntu + macOS matrix
- **DCM** — Dart Code Metrics
- **Markdown** — pymarkdown scan
- **Security** — gitleaks secret scanning

## Release Process

All 6 packages are released together at the same version.

### CHANGELOGs

Each package has a `CHANGELOG.md` with an `## Unreleased` section at the
top. During development, add entries under `## Unreleased`. At release
time the stamp script replaces it with the version heading.

### Steps

```bash
# 1. Review ## Unreleased sections, add any missing entries

# 2. Trigger dry-run (validates, builds, stamps, but does NOT publish or tag)
gh workflow run "Prepare release" -f version=X.Y.Z

# 3. If green, trigger real publish
gh workflow run "Prepare release" -f version=X.Y.Z -f publish=true

# 4. release.yaml auto-triggers from the tag → builds GitHub Release

# 5. Verify all 6 packages are live on pub.dev
bash tool/verify_publish.sh X.Y.Z
```

Do NOT manually stamp changelogs or bump pubspecs — the workflow handles
all of that automatically.

### What the workflow does

| Step | Always | Publish only |
|------|--------|--------------|
| Generate FFI bindings | x | |
| Analyze all packages | x | |
| Run tests (dart + flutter) | x | |
| Build native binaries (Linux + macOS) | x | |
| Bump versions in all pubspecs | x | |
| Stamp CHANGELOGs | x | |
| Verify CHANGELOG entries | x | |
| dartdoc dry-run (all 5 sub-packages) | x | |
| Commit version bumps | x | |
| `dart pub publish --dry-run` | x | |
| Tag and push (commit + tag to main) | | x |
| Publish to pub.dev (leaf-first order) | | x |
| Verify pub.dev versions | | x |

### Known Gotchas

- **FFI bindings are generated, not committed.** The release workflow runs
  `generate_bindings.sh` before analyze and dartdoc. If you add a new
  package that depends on FFI bindings, ensure the release workflow
  generates them too.
- **Dry-run publish warnings are expected.** `publish.sh` swaps path deps
  to version constraints, which makes `dart pub publish --dry-run` warn
  about modified files (exit 65). For first-time publishes, sibling
  packages are not yet on pub.dev, causing dep resolution failures
  (exit 69). Both are handled gracefully.
- **Publish order matters.** `publish.sh` publishes in dependency order:
  `platform_interface` → `ffi` → `wasm` → `web` → `desktop` → root.
  This ensures each package's dependencies are on pub.dev before it
  publishes.
- **dart_monty_web has no tests.** It is a thin Flutter registration shim
  that delegates to `dart_monty_wasm`. The release workflow skips
  `flutter test` for it.
- **pub.dev auth:** The workflow uses `PUB_TOKEN` secret. Set up
  automated publishing via OIDC for a more robust approach (see
  [pub.dev automated publishing](https://dart.dev/tools/pub/automated-publishing)).

### Scripts

- `tool/stamp_changelogs.sh <version>` — stamps all 6 CHANGELOGs
- `tool/publish.sh` — dry-run by default, `--publish` to publish for real
- `tool/verify_publish.sh <version>` — checks pub.dev API with retries

## Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See `test/fixtures/python_ladder/` for the fixture files.
