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
bash tool/test_platform_interface.sh          # M1: platform interface
bash tool/test_rust.sh          # M2: Rust + WASM
bash tool/test_ffi.sh         # M3A: FFI package
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

GitHub Actions run on every push and PR to `main`. All jobs run in
parallel except where noted:

- **FFI bindings** — generates `dart_monty_bindings.dart` once, uploads
  as artifact for downstream jobs (~2 min)
- **Lint** — format + analyze all sub-packages (needs: ffigen)
- **Test** — per-package matrix with 90% coverage gate:
  platform_interface, ffi, wasm (needs: ffigen for ffi variant)
- **Test desktop** — Flutter test + 90% coverage on macOS (needs: ffigen)
- **Test web** — Flutter test on Chrome
- **Rust** — fmt + clippy + tarpaulin test/coverage (90% gate)
- **Build WASM** — `cargo build --target wasm32-wasip1-threads` (needs: rust)
- **Build JS wrapper** — npm install + esbuild bridge/worker
- **Build smoke** — full Flutter desktop build on Ubuntu + macOS (needs: ffigen)
- **WASM ladder** — headless Chrome integration tests
- **DCM** — Dart Code Metrics (weekly + push to main)
- **Markdown** — pymarkdown scan
- **TruffleHog** — verified secret scanning (separate workflow, all pushes)

## Release Process

Packages are published individually to pub.dev using **OIDC automated
publishing**. No tokens or secrets needed — GitHub Actions generates a
short-lived OIDC token that pub.dev verifies directly.

Each package has a dedicated publish workflow triggered by a tag push:

| Package | Tag pattern | Workflow |
|---------|-------------|----------|
| `dart_monty_platform_interface` | `platform_interface-v<version>` | `publish_platform_interface.yaml` |
| `dart_monty_ffi` | `ffi-v<version>` | `publish_ffi.yaml` |
| `dart_monty_wasm` | `wasm-v<version>` | `publish_wasm.yaml` |
| `dart_monty_web` | `web-v<version>` | `publish_web.yaml` |
| `dart_monty_desktop` | `desktop-v<version>` | `publish_desktop.yaml` |
| `dart_monty` | `dart_monty-v<version>` | `publish_dart_monty.yaml` |

### Pre-release checklist

1. **Verify CI is green** on `main` — every job must pass before tagging:
   - **Dart analyze** — zero issues across all packages
     (`python3 tool/analyze_packages.py`)
   - **Dart tests** — platform_interface, ffi, wasm must pass
   - **Dart coverage** — 90%+ line coverage per package (enforced by CI)
   - **Rust** — `cargo fmt`, `cargo clippy`, `cargo test`, and tarpaulin
     coverage at 90%+ must all pass
   - **Build WASM** — `cargo build --target wasm32-wasip1-threads`
   - **Build JS wrapper** — esbuild bridge/worker
   - **Build native** — Ubuntu + macOS matrix
   - **DCM, Markdown, Security** — all must be green
2. **Verify mock and sealed-class completeness** — if new abstract methods
   or sealed variants were added to `platform_interface` or `wasm_bindings`:
   - Update `MockMontyPlatform` in platform_interface tests
   - Update `MockWasmBindings` in dart_monty_web tests
   - Ensure all `switch` statements on sealed types (e.g. `MontyProgress`)
     are exhaustive in every package (especially desktop)
3. **Update version** in each package's `pubspec.yaml` that you intend to
   release
4. **Consolidate CHANGELOGs** — rename `## Unreleased` to the version
   heading (e.g. `## 0.4.0`) in each package being released
5. **Check dependency constraints** — if `platform_interface` has breaking
   changes, update version constraints in downstream packages (`ffi`, `wasm`,
   `web`, `desktop`, `dart_monty`). Remember `^0.3.3` means `>=0.3.3 <0.4.0`,
   so a 0.4.0 release requires bumping constraints to `^0.4.0`.
6. **Commit and push** the version bumps and CHANGELOG updates to `main`
7. **Run local dry-run** for each package being published:
   ```bash
   cd packages/<package> && dart pub publish --dry-run
   ```

### Release (tagging and publishing)

Tag and push in **dependency order** — each package's deps must be live on
pub.dev before it publishes:

```bash
# 1. platform_interface (no monty deps)
git tag platform_interface-v<version>
git push origin platform_interface-v<version>
# Wait for workflow to complete successfully

# 2. ffi and wasm (depend on platform_interface)
git tag ffi-v<version>
git tag wasm-v<version>
git push origin ffi-v<version> wasm-v<version>
# Wait for both workflows to complete

# 3. web and desktop (depend on platform_interface + ffi/wasm)
git tag web-v<version>
git tag desktop-v<version>
git push origin web-v<version> desktop-v<version>
# Wait for both workflows to complete

# 4. dart_monty root (depends on web + desktop)
git tag dart_monty-v<version>
git push origin dart_monty-v<version>
# Wait for workflow to complete

# 5. GitHub Release (builds native + web artifacts)
git tag v<version>
git push origin v<version>
```

Steps 1–4 publish to **pub.dev** via per-package OIDC workflows.
Step 5 triggers `release.yaml` which builds native binaries (Linux + macOS),
a web bundle, and creates a **GitHub Release** at
`https://github.com/runyaga/dart_monty/releases` with all artifacts attached.

### Post-release verification

1. **Check pub.dev** — verify each package shows the new version:
   ```bash
   for pkg in dart_monty_platform_interface dart_monty_ffi dart_monty_wasm \
              dart_monty_web dart_monty_desktop dart_monty; do
     echo "$pkg: $(curl -s https://pub.dev/api/packages/$pkg | python3 -c \
       "import sys,json; print(json.load(sys.stdin)['latest']['version'])")"
   done
   ```
2. **Check GitHub Actions** — all 6 publish workflows + release workflow should
   show green
3. **Check GitHub Release** — verify
   `https://github.com/runyaga/dart_monty/releases` shows the new version with
   native (linux-x64, macos-x64) and web artifacts attached
4. **Test downstream** — create a fresh project and add `dart_monty` as a
   dependency to verify the published packages resolve correctly:
   ```bash
   dart create test_install && cd test_install
   dart pub add dart_monty
   ```

### Post-release cleanup

After all packages are published:

1. **Reset CHANGELOGs** — add `## Unreleased` heading above the just-released
   version in every package's `CHANGELOG.md`
2. **Commit and push** the reset to `main`:
   ```bash
   git add */CHANGELOG.md packages/*/CHANGELOG.md
   git commit -m "chore: reset CHANGELOGs to Unreleased"
   git push origin main
   ```

### If a publish fails

- Check the Actions log for the exact error
- Fix the issue on `main`
- **If the version was NOT yet published** — delete the old tag, fix, re-tag
  on the new commit, and push:
  ```bash
  git tag -d <tag> && git push origin :refs/tags/<tag>
  # fix and push to main
  git tag <tag> && git push origin <tag>
  ```
- **If the version WAS already published** — bump to the next patch version,
  update CHANGELOG, commit, and tag the new version. A published version can
  never be re-published.
- **Root package `dart_monty`** depends on all sub-packages from pub.dev (not
  path refs). If it fails with "doesn't match any versions", wait 1–2 minutes
  for pub.dev propagation after the dependency packages publish, then re-tag.

### CHANGELOGs

Each package has a `CHANGELOG.md`. During development, add entries under
`## Unreleased`. Before publishing, rename `## Unreleased` to the version
heading. pub.dev displays the CHANGELOG entry matching the published version
as the release notes.

### pub.dev admin setup (one-time per package)

All 6 packages are already configured. For new packages:

1. Publish the first version manually with `dart pub publish`
2. Go to `https://pub.dev/packages/<package_name>/admin`
3. Enable **Automated publishing** from GitHub Actions
4. Set **Repository:** `runyaga/dart_monty`
5. Set **Tag pattern:** `<prefix>-v{{version}}`
6. Save

### Publishing gotchas

- **Tag filters use glob, not regex.** GitHub Actions `on.push.tags` uses
  glob matching — `[0-9]+` is literal (matches `1+`), use `[0-9]*` for
  "one or more digits".
- **Flutter packages need both actions for OIDC.** `subosito/flutter-action`
  does not configure OIDC credentials. Flutter publish workflows must also
  include `dart-lang/setup-dart@v1` to enable `dart pub publish` with OIDC.
- **FFI bindings are generated, not committed.** The `publish_ffi.yaml`
  workflow includes `apt-get install libclang-dev` and `dart run ffigen`
  steps because `dart_monty_bindings.dart` is gitignored.
- **Root package resolves from pub.dev.** `dart_monty` uses hosted
  dependencies (`^x.y.z`), not path refs. After publishing sub-packages,
  wait 1–2 minutes for pub.dev to propagate before tagging the root.
- **Sealed-class exhaustiveness.** Adding a variant to `MontyProgress` (or
  any sealed class) requires updating every `switch` on that type across all
  packages and all mock implementations.

## Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See `test/fixtures/python_ladder/` for the fixture files.
