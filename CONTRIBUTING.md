# Contributing to dart_monty

## Prerequisites

- Dart SDK >= 3.10.0
- Rust stable (for native builds)
- Node.js >= 20 (for WASM JS bridge)
- Python 3.12+ (for tooling scripts)
- Flutter SDK (optional — only needed for Flutter-specific integration tests)

## Quick Start

```bash
dart pub get
dart format .
dart analyze --fatal-infos
dart test
```

## Running Examples

### Native (desktop)

Runs Python from Dart via FFI into the Rust native library.
`dart_monty_core`'s `hook/build.dart` compiles the dylib
automatically on `dart pub get` — no manual cargo step needed.

```bash
bash example/native/run.sh
```

### Web (browser)

Runs Python from Dart compiled to JS, via a Web Worker hosting the
WASM interpreter. The run script stages `dart_monty_core`'s committed
assets into the example's `web/` dir and serves with COOP/COEP
headers.

```bash
bash example/web/run.sh
```

To point the script at an in-progress `dart_monty_core` checkout
(instead of the pub cache), set `DART_MONTY_CORE_DIR`:

```bash
DART_MONTY_CORE_DIR=/path/to/dart_monty_core bash example/web/run.sh
```

## Gate Scripts

```bash
bash tool/gate.sh                        # Run ALL quality checks
bash tool/test_platform_interface.sh     # Platform interface
bash tool/test_ffi.sh                    # FFI tests
bash tool/test_python_ladder.sh          # Python ladder (all backends)
bash tool/test_cross_path_parity.sh      # JSONL parity diff
```

## Code Quality

Run these checks after every code change:

1. `dart format .` — must produce no changes
2. `dart analyze --fatal-infos` — must report zero issues
3. `dart test` — must pass all tests
4. Maintain 90%+ line coverage (enforced by CI and pre-push hooks)

## CI

GitHub Actions run on every push and PR to `main`. Docs-only changes
(markdown, `docs/`, LICENSE) skip all code jobs — only the **Markdown
lint** job runs. This is handled by a `changes` detection job using
`dorny/paths-filter@v3`.

All code jobs run in parallel except where noted:

- **Changes** — detects code vs docs-only changes (~2s, always runs)
- **FFI bindings** — generates `dart_monty_bindings.dart` once, uploads
  as artifact for downstream jobs (~2 min)
- **Lint** — format + analyze (needs: ffigen)
- **Test** — single test job with 90% coverage gate (needs: ffigen).
  Coverage is enforced by the `.github/actions/enforce-coverage`
  composite action.
- **Rust** — fmt + clippy + tarpaulin test/coverage (85% gate)
- **Build WASM** — `cargo build --target wasm32-wasip1-threads` (needs: rust)
- **Build JS wrapper** — npm install + esbuild bridge/worker
- **Build smoke** — full Flutter desktop build on Ubuntu + macOS (needs: ffigen)
- **WASM ladder** — headless Chrome integration tests
- **DCM** — Dart Code Metrics (weekly + push to main)
- **Markdown** — pymarkdown scan (always runs, even on docs-only changes)
- **TruffleHog** — verified secret scanning (separate workflow, all pushes)

## Release Process

The project is published as a single `dart_monty` package to pub.dev
using **OIDC automated publishing**. No tokens or secrets needed — GitHub
Actions generates a short-lived OIDC token that pub.dev verifies directly.

A version tag triggers one workflow:

- `publish_dart_monty.yaml` — publishes to pub.dev via OIDC

(The legacy `release.yaml` / `native-release.yaml` /
`prepare-release.yaml` workflows have been retired — they referenced
the removed `native/` directory. Native artefacts now live in
`dart_monty_core` and are built via its own `hook/build.dart` +
native-asset hook toolchain.)

### Pre-release checklist

1. **Verify CI is green** on `main` — every job must pass before tagging:
   - **Dart analyze** — zero issues (`dart analyze --fatal-infos`)
   - **Dart tests** — all tests pass with 90%+ line coverage
   - **Rust** — `cargo fmt`, `cargo clippy`, `cargo test`, and tarpaulin
     coverage at 90%+ must all pass
   - **Build WASM** — `cargo build --target wasm32-wasip1-threads`
   - **Build JS wrapper** — esbuild bridge/worker
   - **Build native** — Ubuntu + macOS matrix
   - **DCM, Markdown, Security** — all must be green
2. **Verify mock and sealed-class completeness** — if new abstract methods
   or sealed variants were added:
   - Update `MockMontyPlatform` in platform interface tests
   - Ensure all `switch` statements on sealed types (e.g. `MontyProgress`)
     are exhaustive
3. **Update version** in `pubspec.yaml`
4. **Update CHANGELOG** — rename `## Unreleased` to the version heading
   (e.g. `## 0.20.0`)
5. **Commit and push** the version bump and CHANGELOG update to `main`
6. **Run local dry-run:**

   ```bash
   dart pub publish --dry-run
   ```

### Release (tagging and publishing)

```bash
git tag v<version>
git push origin v<version>
```

This triggers both `publish_dart_monty.yaml` (pub.dev) and `release.yaml`
(native binaries for Linux + macOS, web bundle, GitHub Release at
`https://github.com/runyaga/dart_monty/releases`).

### Post-release verification

1. **Check pub.dev** — verify the new version is live:

   ```bash
   curl -s https://pub.dev/api/packages/dart_monty | python3 -c \
     "import sys,json; print(json.load(sys.stdin)['latest']['version'])"
   ```

2. **Check GitHub Actions** — publish + release workflows should show green
3. **Check GitHub Release** — verify
   `https://github.com/runyaga/dart_monty/releases` shows the new version with
   native (linux-x64, macos-x64) and web artifacts attached
4. **Test downstream** — create a fresh project and add `dart_monty` as a
   dependency to verify the published package resolves correctly:

   ```bash
   dart create test_install && cd test_install
   dart pub add dart_monty
   ```

### Post-release cleanup

After publishing:

1. **Reset CHANGELOG** — add `## Unreleased` heading above the just-released
   version in `CHANGELOG.md`
2. **Commit and push** the reset to `main`:

   ```bash
   git add CHANGELOG.md
   git commit -m "chore: reset CHANGELOG to Unreleased"
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

### CHANGELOGs

The project has a single `CHANGELOG.md` at the root. During development, add
entries under `## Unreleased`. Before publishing, rename `## Unreleased` to the
version heading. pub.dev displays the CHANGELOG entry matching the published
version as the release notes.

### pub.dev admin setup (one-time)

The `dart_monty` package is already configured. If reconfiguring:

1. Publish the first version manually with `dart pub publish`
2. Go to `https://pub.dev/packages/dart_monty/admin`
3. Enable **Automated publishing** from GitHub Actions
4. Set **Repository:** `runyaga/dart_monty`
5. Set **Tag pattern:** `v{{version}}`
6. Set **Environment:** `pub-dev`
7. Save

### Publishing gotchas

- **OIDC requires `environment: pub-dev`.** The package on pub.dev is
  configured with the `pub-dev` environment restriction. The publish
  workflow must have `environment: pub-dev` on its job — without it,
  `dart pub publish` fails with `Authentication failed!`.
- **`pub-dev` environment needs a tag deployment policy.** The GitHub
  `pub-dev` environment must have a deployment branch policy allowing
  tags matching `v*`. Without this, tag pushes silently fail to
  trigger the publish workflow. Check via Settings > Environments >
  pub-dev > Deployment branches and tags.
- **Tag filters use glob, not regex.** GitHub Actions `on.push.tags` uses
  glob matching — `[0-9]+` is literal (matches `1+`), use `[0-9]*` for
  "one or more digits".
- **Flutter packages need both actions for OIDC.** `subosito/flutter-action`
  does not configure OIDC credentials. If the publish workflow uses Flutter,
  it must also include `dart-lang/setup-dart@v1` to enable `dart pub publish`
  with OIDC.
- **FFI bindings are generated, not committed.** The publish workflow
  includes `apt-get install libclang-dev` and `dart run ffigen` steps
  because `dart_monty_bindings.dart` is gitignored.
- **Sealed-class exhaustiveness.** Adding a variant to `MontyProgress` (or
  any sealed class) requires updating every `switch` on that type and all
  mock implementations.

## Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See `test/fixtures/python_ladder/` for the fixture files.
