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

## Publishing to pub.dev

Packages are published individually using **OIDC automated publishing**.
No tokens or secrets needed — GitHub Actions generates a short-lived OIDC
token that pub.dev verifies directly.

### How it works

Each package has a dedicated publish workflow triggered by a tag push:

| Package | Tag pattern | Workflow |
|---------|-------------|----------|
| `dart_monty` | `dart_monty-v<version>` | `publish_dart_monty.yaml` |
| `dart_monty_platform_interface` | `platform_interface-v<version>` | `publish_platform_interface.yaml` |
| `dart_monty_ffi` | `ffi-v<version>` | `publish_ffi.yaml` |
| `dart_monty_wasm` | `wasm-v<version>` | `publish_wasm.yaml` |
| `dart_monty_web` | `web-v<version>` | `publish_web.yaml` |
| `dart_monty_desktop` | `desktop-v<version>` | `publish_desktop.yaml` |

The workflow runs: install deps → analyze → test → verify tag matches
pubspec version → dry-run → publish.

### Publishing a package

```bash
# 1. Ensure CHANGELOG.md has an entry for the version (no "Unreleased" heading)
# 2. Ensure pubspec.yaml version matches the tag you're about to push
# 3. Tag and push (example for platform_interface)
git tag platform_interface-v0.3.5
git push origin platform_interface-v0.3.5
# 4. Watch the Actions tab for the publish workflow
```

### Publish order

Publish in dependency order to ensure each package's deps are on pub.dev:

`platform_interface` → `ffi` / `wasm` → `web` / `desktop` → `dart_monty`

### pub.dev admin setup (one-time per package)

1. Go to `https://pub.dev/packages/<package_name>/admin`
2. Enable **Automated publishing** from GitHub Actions
3. Set **Repository:** `runyaga/dart_monty`
4. Set **Tag pattern:** `<prefix>-v{{version}}` (e.g. `platform_interface-v{{version}}`)
5. Save

### If a publish fails

- Check the Actions log for the exact error
- Fix the issue, bump the version (a published version can never be re-published)
- Update CHANGELOG.md with the new version entry
- Tag and push the new version

### CHANGELOGs

Each package has a `CHANGELOG.md`. During development, add entries under
`## Unreleased`. Before publishing, rename `## Unreleased` to the version
heading (e.g. `## 0.3.5`).

## Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See `test/fixtures/python_ladder/` for the fixture files.
