# Contributing to dart_monty

## Prerequisites

- Dart SDK >= 3.10.0
- Python 3.12+ (for tooling scripts)
- Flutter SDK (optional — only needed for Flutter-specific integration tests)

## Quick Start

```bash
dart pub get
dart format .
dart analyze --fatal-infos
dart test
```

## Working Against a Local `dart_monty_core` Checkout

When iterating on `dart_monty` and `dart_monty_core` together
(rather than against a tagged release), wire up both halves:

1. **Pub resolution** — create `pubspec_overrides.yaml` (gitignored) at
   the repo root pointing pub at your local checkout:

   ```yaml
   dependency_overrides:
     dart_monty_core:
       path: /path/to/dart_monty_core
   ```

   The same file is needed in `example/web/pubspec_overrides.yaml`
   for the ladder gate to resolve.

2. **Asset staging** — for the `example/web/run.sh` and
   `tool/test_python_ladder.sh` scripts (which copy `dart_monty_core`'s
   bridge JS / WASM into the example), set `DART_MONTY_CORE_DIR`:

   ```bash
   export DART_MONTY_CORE_DIR=/path/to/dart_monty_core
   ```

   Without it, the scripts fall back to the pub cache.

## Running Examples

### Native (desktop)

Runs Python from Dart through the native worker from `dart_monty_core`.
See `docs/contributor/setup.md` for building it.

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

## Gate Scripts

```bash
bash tool/gate.sh                        # Run ALL quality checks
bash tool/test_python_ladder.sh          # Python ladder (WASM, headless Chrome)
bash tool/check_core_ref.sh              # Check the shared core Git ref
bash tool/check_no_core_src_imports.sh   # Keep imports on core's public API
```

`tool/check_core_ref.sh` keeps every tracked YAML core reference on the pin in
`pubspec.yaml`. `tool/check_no_core_src_imports.sh` rejects imports from core
implementation libraries.

## Code Quality

Run these checks after every code change:

1. `dart format .` — must produce no changes
2. `dart analyze --fatal-infos` — must report zero issues
3. `dart test` — must pass all tests
4. Maintain 90%+ line coverage (enforced by CI and pre-push hooks)

## Bug Triage

Before filing a bug against `dart_monty`, walk it down the stack to
locate the layer where it actually lives. Filing at the wrong layer
costs time and obscures real upstream issues.

### The stack

```
dart_monty (this repo)               <- bridge, runtime, extensions, host fns
    |
dart_monty_core (Dart wrapper)       <- Monty / MontyRepl / MontyResult, JSON
    |                                   value envelopes (__type: dataclass, …)
dart_monty_core (Rust shim)          <- native/src/convert.rs etc. — JSON ↔
    |                                   typed MontyObject conversion
pydantic/monty (Rust upstream)       <- the interpreter itself, MontyObject
                                        enum, externals, REPL
```

A bug surfaces in `dart_monty`. Walk **down**, layer by layer, until
the bug stops reproducing. The lowest layer where it still reproduces
is where to file.

### Triage workflow

1. **Slim the reproducer.** Strip the failing case to the smallest
   self-contained Dart program that uses only `package:dart_monty`. No
   plugins, no extensions, no HTTP, no HostContext gymnastics — just
   the suspect code path. Save it as `/tmp/reproducer.dart`.

2. **Reproduce against `dart_monty_core` directly.** Skip
   `dart_monty`'s bridge by replacing `MontyRuntime`/`HostFunction`
   with `Monty(code).run(externalFunctions: ...)` or `MontyRepl`. Add
   only `package:dart_monty_core/dart_monty_core.dart` to the
   reproducer:

   ```dart
   import 'package:dart_monty_core/dart_monty_core.dart';

   Future<void> main() async {
     // … the same logic, but through Monty/MontyRepl, not MontyRuntime
   }
   ```

   - **Reproduces here too** → bug is at the `dart_monty_core` Dart
     layer or below. Continue to step 3.
   - **Does not reproduce** → bug is in `dart_monty`'s bridge / runtime
     / extensions. File on **this** repo with the slim reproducer.

3. **Reproduce against the Rust shim directly (`dart_monty_core` Rust
   side).** If the bug involves JSON envelope handling
   (`__type: dataclass`, `__type: bytes`, etc.), inspect the symmetric
   pair in `dart_monty_core/native/src/convert.rs` —
   `monty_object_to_json` and `json_to_monty_object`. Diff the two: if
   one path normalises a field the other path doesn't, you've found
   the asymmetry. A failing fixture at the shim layer is enough; you
   don't have to write Rust to triage.

   - **Reproduces with symmetric envelopes** → continue to step 4.
   - **Asymmetry in `convert.rs`** → file on **`dart_monty_core`**
     against the Rust shim.

4. **Reproduce against `pydantic/monty` upstream.** This is the highest
   bar; do it when steps 1–3 didn't localise the bug. A small
   Rust binary that pulls in `monty = { git = ..., tag = "v0.0.17" }`
   and exercises the typed `MontyObject` API directly tells you
   whether upstream is the source. If the bug only shows when a JSON
   envelope is involved, it's almost never an upstream-Rust bug —
   pydantic/monty doesn't see the JSON, only the typed `MontyObject`
   variants.

   - **Reproduces against pydantic/monty** → file upstream at
     <https://github.com/pydantic/monty>.
   - **Does not reproduce** → the bug is in `dart_monty_core`'s shim
     or wrapper. File on `dart_monty_core` with the layered evidence.

### What goes in the bug report

Whichever layer you file at:

- the slim reproducer (one file, no external services, deterministic);
- the layers you tried and which ones reproduced or didn't (show your
  work — saves the next person 30 minutes);
- the file:line trace of the relevant code path on each layer
  (`grep -n` output is fine).

### Why this matters

Filing a "dart_monty bug" that's actually a `dart_monty_core` Rust
shim asymmetry routes the wrong people to the wrong code. Filing a
"dart_monty_core bug" that's actually upstream pydantic/monty
behaviour wastes a wrap-side fix attempt that won't hold. The triage
walk costs 5–15 minutes; misrouting costs hours per side.

## CI

GitHub Actions run on every push and PR to `main`. Docs-only changes
(markdown, `docs/`, LICENSE) skip all code jobs — only the **Markdown
lint** job runs. This is handled by a `changes` detection job using
`dorny/paths-filter@v3`.

All code jobs run in parallel except where noted:

- **Changes**: detects code vs docs-only changes (always runs)
- **Gate**: pins, workflow checks, format and analyze
- **Dart test**: unit tests with a coverage gate and core's prebuilt worker
- **Integration tests**: the VM cell with core's prebuilt worker
- **Demo pages**: the published pages in headless Chrome, plus the
  workspace caps tests
- **Browser cell** (matrix): the integration and acceptance suites in
  `chrome-dart2js`, `chrome-dart2wasm`, `firefox-dart2js` and
  `firefox-dart2wasm`, each held to its floor in `tool/test_floors.tsv`
- **Coverage merge and patch coverage**: unit plus integration coverage
  against the patch
- **Markdown** — pymarkdown scan (always runs, even on docs-only changes)
- **TruffleHog** — verified secret scanning (separate workflow, all pushes)

## Release Process

This package is never published to pub.dev. Releases are immutable Git tags;
there is no publishing workflow or pub.dev release step.

Native artefacts live in `dart_monty_core`. This repository has no native
code and no release binaries.

### Pre-release checklist

1. **Verify CI is green** on `main` — every job must pass before tagging:
   - **Dart analyze** — zero issues (`dart analyze --fatal-infos`)
   - **Dart tests** — all tests pass with 90%+ line coverage
   - **Integration tests**: every platform cell passes with its floor
     (`vm`, `chrome-dart2js`, `chrome-dart2wasm`, `firefox-dart2js`,
     `firefox-dart2wasm`)
   - **Markdown, Security**: all must be green
   - **DCM**: `bash tool/dcm_host_gate.sh` passes on the host
2. **Verify mock and sealed-class completeness** — if new abstract methods
   or sealed variants were added:
   - Update `MockMontyPlatform` in platform interface tests
   - Ensure all `switch` statements on sealed types (e.g. `MontyProgress`)
     are exhaustive
3. **Update version** in `pubspec.yaml`
4. **Update CHANGELOG** — rename `## Unreleased` to the version heading
   (e.g. `## 0.17.0`)
5. **Commit and push** the version bump and CHANGELOG update to `main`
6. **Run local dry-run:**

   ```bash
   dart pub publish --dry-run
   ```

### Release (tagging)

```bash
git tag v<version>
git push origin v<version>
```

The pushed tag is the release. Do not delete, move, or recreate a release tag.

### Post-release verification

1. **Check GitHub**: verify the tag points at the intended release commit.
2. **Test downstream**: create a fresh project with the release tag as its
   Git dependency and run `dart pub get`:

   ```bash
   dart create test_install && cd test_install
   dart pub add dart_monty --git-url https://github.com/runyaga/dart_monty.git \
     --git-ref v<version>
   ```

### Post-release cleanup

After release:

1. **Reset CHANGELOG** — add `## Unreleased` heading above the just-released
   version in `CHANGELOG.md`
2. **Commit and push** the reset to `main`:

   ```bash
   git add CHANGELOG.md
   git commit -m "chore: reset CHANGELOG to Unreleased"
   git push origin main
   ```

### If a release issue is found

- Fix the issue on `main`, update the version and CHANGELOG, then create a new
  tag. Existing release tags are immutable and must not be moved or reused.

### CHANGELOGs

The project has a single `CHANGELOG.md` at the root. During development, add
entries under `## Unreleased`. Before a release, rename `## Unreleased` to the
version heading. The matching CHANGELOG entry records that tagged release.
Document every breaking change. Pin versions and read the changelog before
upgrading.

### Release gotchas

- **Tags are immutable.** If a release needs correction, create a new version
  and tag; never force-push or move an existing release tag.
- **Sealed-class exhaustiveness.** Adding a variant to `MontyProgress` (or
  any sealed class) requires updating every `switch` on that type and all
  mock implementations.

## Cross-Platform Parity

Both execution paths produce identical results, verified via the
**Python Compatibility Ladder** — JSON test fixtures across 6 tiers
(expressions, variables, control flow, functions, errors, external
functions). See `test/fixtures/python_ladder/` for the fixture files.
