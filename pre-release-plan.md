# Pre-Release Plan: dart\_monty pub.dev Publication

Checklist and reference for publishing all dart\_monty packages to pub.dev.

---

## 1. LICENSE (MIT)

Every package scored by pub.dev needs its own LICENSE file.

| Location | Action |
|----------|--------|
| `LICENSE` (repo root) | Create — MIT, copyright runyaga |
| `packages/dart_monty_platform_interface/LICENSE` | Copy from root |
| `packages/dart_monty_ffi/LICENSE` | Copy from root |
| `packages/dart_monty_wasm/LICENSE` | Copy from root |
| `packages/dart_monty_web/LICENSE` | Copy from root |
| `packages/dart_monty_native/LICENSE` | Copy from root |

Template (year and holder filled at publish time):

```text
MIT License

Copyright (c) 2025 runyaga

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. README.md per Sub-Package

pub.dev scores each package independently. A missing README costs ~30 points.
Create a brief `README.md` in each sub-package linking back to the main repo.

| Package | File to create |
|---------|---------------|
| `dart_monty_platform_interface` | `packages/dart_monty_platform_interface/README.md` |
| `dart_monty_ffi` | `packages/dart_monty_ffi/README.md` |
| `dart_monty_wasm` | `packages/dart_monty_wasm/README.md` |
| `dart_monty_web` | `packages/dart_monty_web/README.md` |
| `dart_monty_native` | `packages/dart_monty_native/README.md` |

Each should contain a one-paragraph description plus a link:

```markdown
# dart_monty_ffi

Native FFI implementation of dart_monty for desktop and mobile platforms.

See the [main dart_monty repository](https://github.com/runyaga/dart_monty)
for full documentation.
```

---

## 3. Merge Desktop Branch

The `dart_monty_native` package lives on `feat/m5-desktop-plugin`. It
**must be merged to main** before starting the publish process. Publishing
uses the local file tree — switching branches mid-publish would break
path dependency resolution and git tag consistency.

- [ ] Merge `feat/m5-desktop-plugin` into `main`
- [ ] Verify `packages/dart_monty_native/pubspec.yaml` is present after merge

---

## 4. pubspec.yaml Updates

### Package overview

| Package | SDK | Notes |
|---------|-----|-------|
| `dart_monty` | **Flutter** | App-facing federated plugin |
| `dart_monty_platform_interface` | **Dart** (pure) | Abstract contract, no Flutter imports |
| `dart_monty_ffi` | **Dart** (pure) | Native FFI bindings via `dart:ffi` |
| `dart_monty_wasm` | **Dart** (pure) | WASM bindings via `dart:js_interop` |
| `dart_monty_web` | **Flutter** | Web plugin registration (`flutter_web_plugins`) |
| `dart_monty_native` | **Flutter** | macOS/Linux desktop plugin (`dartPluginClass`) |

### Fields to add/change in every package

- **Remove** `publish_to: 'none'`
- **Add** `homepage: https://github.com/runyaga/dart_monty`
- **Add** `repository: https://github.com/runyaga/dart_monty`
- **Add** `issue_tracker: https://github.com/runyaga/dart_monty/issues`
- **Add** `topics:` (max 5 per package, chosen from pool below)
- **Verify** `description` is 180 chars or fewer

Topic pool: `python`, `sandbox`, `interpreter`, `ffi`, `wasm`, `flutter`

### Per-package details

#### dart\_monty — Flutter (root `pubspec.yaml`)

- **Current description** (118 chars — OK):
  `Flutter plugin exposing the Monty sandboxed Python interpreter to Dart/Flutter via FFI (native) and JS interop (web).`
- **Topics:** `python`, `sandbox`, `interpreter`, `flutter`
- **Path deps to convert:**
  - `dart_monty_platform_interface: path: packages/dart_monty_platform_interface` -> `^<current-version>`
- **New deps to add:**
  - `dart_monty_web: ^<current-version>` (currently missing — needed for federated web registration)
  - `dart_monty_native: ^<current-version>` (currently missing — needed for federated desktop registration)
- **Fix `flutter: plugin: platforms:` block:**
  - **Remove** `android`, `ios`, `windows` (not yet implemented — M7 planned)
  - **Change** `macos` and `linux` from `ffiPlugin: true` to `default_package: dart_monty_native`
  - **Change** `web` from `pluginClass`/`fileName` to `default_package: dart_monty_web`

Current (broken for federation):

```yaml
flutter:
  plugin:
    platforms:
      android:
        ffiPlugin: true
      ios:
        ffiPlugin: true
      linux:
        ffiPlugin: true
      macos:
        ffiPlugin: true
      windows:
        ffiPlugin: true
      web:
        pluginClass: DartMontyWeb
        fileName: dart_monty_web.dart
```

Target (correct federated plugin registration):

```yaml
flutter:
  plugin:
    platforms:
      linux:
        default_package: dart_monty_native
      macos:
        default_package: dart_monty_native
      web:
        default_package: dart_monty_web
```

#### dart\_monty\_platform\_interface — pure Dart (`packages/dart_monty_platform_interface/pubspec.yaml`)

- **Current description** (99 chars — OK):
  `Platform interface for dart_monty. Defines the shared API contract implemented by native and web backends.`
  - 105 chars — OK.
- **Topics:** `python`, `sandbox`, `interpreter`
- **Path deps:** None (only pub dependencies)

#### dart\_monty\_ffi — pure Dart (`packages/dart_monty_ffi/pubspec.yaml`)

- **Current description** (103 chars — OK):
  `Native FFI implementation of dart_monty for desktop and mobile platforms (macOS, Linux, Windows, iOS, Android).`
  - 111 chars — OK.
- **Topics:** `python`, `sandbox`, `ffi`, `interpreter`
- **Path dep to convert:** `dart_monty_platform_interface: path: ../dart_monty_platform_interface` -> `^<current-version>`

#### dart\_monty\_wasm — pure Dart (`packages/dart_monty_wasm/pubspec.yaml`)

- **Current description** (83 chars — OK):
  `Web WASM implementation of dart_monty using dart:js_interop and @pydantic/monty.`
  - 81 chars — OK.
- **Topics:** `python`, `sandbox`, `wasm`, `interpreter`
- **Path dep to convert:** `dart_monty_platform_interface: path: ../dart_monty_platform_interface` -> `^<current-version>`

#### dart\_monty\_web — Flutter (`packages/dart_monty_web/pubspec.yaml`)

- **Current description** (87 chars — OK):
  `Web implementation of dart_monty using @pydantic/monty JS package via dart:js_interop.`
- **Topics:** `python`, `sandbox`, `wasm`, `flutter`
- **Path dep to convert:** `dart_monty_platform_interface: path: ../dart_monty_platform_interface` -> `^<current-version>`
- **Verify `flutter: plugin:` block** declares `implements: dart_monty` with
  `pluginClass` and `fileName`. The current pubspec already has the correct
  `flutter:` section — confirm it matches:

```yaml
flutter:
  plugin:
    implements: dart_monty
    platforms:
      web:
        pluginClass: DartMontyWeb
        fileName: dart_monty_web.dart
```

#### dart\_monty\_native — Flutter (`packages/dart_monty_native/pubspec.yaml`, on feat/m5-desktop-plugin)

- **Current description** (62 chars — OK):
  `macOS and Linux implementation of dart_monty using native FFI.`
- **Topics:** `python`, `sandbox`, `ffi`, `flutter`
- **Path deps to convert:**
  - `dart_monty_ffi: path: ../dart_monty_ffi` -> `^<current-version>`
  - `dart_monty_platform_interface: path: ../dart_monty_platform_interface` -> `^<current-version>`
- **Verify `flutter: plugin:` block** declares `implements: dart_monty`.
  The current pubspec already has this — confirm it matches:

```yaml
flutter:
  plugin:
    implements: dart_monty
    platforms:
      macos:
        dartPluginClass: DartMontyNative
        ffiPlugin: true
      linux:
        dartPluginClass: DartMontyNative
        ffiPlugin: true
```

---

## 5. Path Dependencies to Version Constraints

All inter-package `path:` dependencies must become versioned constraints
before `dart pub publish`. The table below lists every conversion.

| Package | Dependency | Current | Target |
|---------|-----------|---------|--------|
| `dart_monty` | `dart_monty_platform_interface` | `path: packages/dart_monty_platform_interface` | `^<current-version>` |
| `dart_monty` | `dart_monty_web` | **new dep** (currently missing) | `^<current-version>` |
| `dart_monty` | `dart_monty_native` | **new dep** (currently missing) | `^<current-version>` |
| `dart_monty_ffi` | `dart_monty_platform_interface` | `path: ../dart_monty_platform_interface` | `^<current-version>` |
| `dart_monty_wasm` | `dart_monty_platform_interface` | `path: ../dart_monty_platform_interface` | `^<current-version>` |
| `dart_monty_web` | `dart_monty_platform_interface` | `path: ../dart_monty_platform_interface` | `^<current-version>` |
| `dart_monty_native` | `dart_monty_platform_interface` | `path: ../dart_monty_platform_interface` | `^<current-version>` |
| `dart_monty_native` | `dart_monty_ffi` | `path: ../dart_monty_ffi` | `^<current-version>` |

### Publish order

Packages must be published in dependency order (leaf-first):

1. **dart\_monty\_platform\_interface** — zero internal deps
2. **dart\_monty\_ffi** — deps: platform\_interface
3. **dart\_monty\_wasm** — deps: platform\_interface
4. **dart\_monty\_web** — deps: platform\_interface
5. **dart\_monty\_native** — deps: platform\_interface, ffi
6. **dart\_monty** — deps: platform\_interface, web, desktop

Steps 2-4 can be published in parallel once step 1 is live.
Step 5 requires steps 1 and 2. Step 6 requires steps 1-5.

---

## 6. CHANGELOG.md

Create an initial `CHANGELOG.md` in each package root with a version
heading matching the pubspec version. pub.dev displays this on the
package page.

| Package | File to create |
|---------|---------------|
| `dart_monty` | `CHANGELOG.md` |
| `dart_monty_platform_interface` | `packages/dart_monty_platform_interface/CHANGELOG.md` |
| `dart_monty_ffi` | `packages/dart_monty_ffi/CHANGELOG.md` |
| `dart_monty_wasm` | `packages/dart_monty_wasm/CHANGELOG.md` |
| `dart_monty_web` | `packages/dart_monty_web/CHANGELOG.md` |
| `dart_monty_native` | `packages/dart_monty_native/CHANGELOG.md` |

### Suggested content per package

**dart\_monty:**

```markdown
## <version>

- Initial release.
- Federated plugin exposing Monty sandboxed Python interpreter.
- Supports native (FFI) and web (JS interop) execution paths.
```

**dart\_monty\_platform\_interface:**

```markdown
## <version>

- Initial release.
- Defines `MontyPlatform` abstract contract, `MontyResult`, `MontyException`,
  `MontyResourceUsage`, and iterative execution types.
```

**dart\_monty\_ffi:**

```markdown
## <version>

- Initial release.
- Native FFI bindings to libdart_monty_native Rust library.
- Supports macOS, Linux, Windows, iOS, and Android.
```

**dart\_monty\_wasm:**

```markdown
## <version>

- Initial release.
- Web WASM implementation using @pydantic/monty via dart:js_interop.
- Worker-based execution for Chrome WASM compile-size limits.
```

**dart\_monty\_web:**

```markdown
## <version>

- Initial release.
- Flutter web plugin registration for dart_monty.
- Delegates to dart_monty_wasm for WASM execution.
```

**dart\_monty\_native:**

```markdown
## <version>

- Initial release.
- macOS and Linux desktop plugin with Isolate-based execution.
- FlutterMonty widget for Flutter desktop apps.
```

---

## 7. Dartdoc Coverage

pub.dev awards up to 10 points for API documentation. `dartdoc` must
generate without warnings.

### Validated findings (Gemini 3.1-pro review of all 17 source files)

Override methods (`==`, `hashCode`, `toString`, `toJson`, `run`,
`resume`, etc.) all **inherit dartdoc** from their parent class. The
pana scorer does not penalize these. The actual gaps are small.

### dart\_monty\_platform\_interface

- `MontyProgress()` — explicit unnamed constructor missing dartdoc
- `MockMontyPlatform` — implicit default constructor missing dartdoc
- **Recommendation:** Move `MockMontyPlatform` export out of the main
  barrel file (`dart_monty_platform_interface.dart`) into a dedicated
  `lib/dart_monty_testing.dart`. It is a test utility that pollutes
  autocomplete for end-users. If it is only used by sibling packages,
  move it to `test/` entirely.

### dart\_monty\_ffi

- `NativeBindings` — implicit default constructor missing dartdoc

### dart\_monty\_wasm

- `WasmBindings` — implicit default constructor missing dartdoc
- `WasmBindingsJs` — implicit default constructor missing dartdoc

### dart\_monty (root) and dart\_monty\_web — CRITICAL

Both packages have **empty `lib/` directories** — zero Dart files.
`dartdoc` generates nothing and pub.dev scores zero for documentation.

- `dart_monty` needs a barrel file re-exporting the platform interface
- `dart_monty_web` needs a barrel file declaring the web plugin class

### Fix pattern for implicit constructors

Add an explicit constructor with a one-line dartdoc to each class:

```dart
/// Creates a [ClassName].
ClassName();
```

### Verification

```bash
dart doc --dry-run   # from each package directory
```

---

## 8. Example Files

pub.dev awards points for an `example/` directory with a Dart file.
Current state and required actions:

| Package | Has example? | Action |
|---------|-------------|--------|
| `dart_monty` | Yes (`example/native/`, `example/web/`) | Verify `example/example.dart` exists at package root (pub.dev expects this specific path) |
| `dart_monty_platform_interface` | No | Create `packages/dart_monty_platform_interface/example/example.dart` |
| `dart_monty_ffi` | No | Create `packages/dart_monty_ffi/example/example.dart` |
| `dart_monty_wasm` | No | Create `packages/dart_monty_wasm/example/example.dart` |
| `dart_monty_web` | No | Create `packages/dart_monty_web/example/example.dart` |
| `dart_monty_native` | No | Create `packages/dart_monty_native/example/example.dart` |

Each `example/example.dart` should be a minimal, self-contained snippet
showing basic usage. pub.dev renders this file on the "Example" tab.

---

## 9. Native Binary Distribution

### Current state

- Native binaries (`libdart_monty_native.dylib`, `.so`) are **gitignored**
  and not checked into any package directory.
- `.github/workflows/release.yaml` builds for **linux-x64** and
  **macos-x64**, compiles the Dart AOT example, packages tarballs, and
  attaches them to **GitHub Releases** on tag push (`v*`).
- `dart_monty_native`'s macOS podspec and Linux CMakeLists.txt expect
  vendored binaries in the plugin's platform directory.

### Problem

If a developer adds `dart_monty` to their pubspec, runs `flutter build macos`,
and it fails because no `.dylib` is present, they will uninstall the
package. Flutter plugins are expected to work out-of-the-box.

pub.dev allows up to **100 MB per package upload**, so vendoring binaries
is feasible.

### Options (pick one before publishing)

**Option A — Vendor binaries in the pub.dev upload (recommended).**
Un-gitignore the built `.dylib`/`.so` inside `dart_monty_native`'s
platform directories (`macos/`, `linux/`). CI builds them, copies them
in, and `dart pub publish` includes them. This is what `realm` and
`sqlite3_flutter_libs` do.

**Option B — Auto-download during native build.**
Modify the macOS podspec `script_phase` and Linux CMakeLists.txt to
`curl` the exact tarball from GitHub Releases (matching the pubspec
version tag) during `flutter build`. More complex, but keeps the pub.dev
upload small.

**Option C — Manual (document-only, worst UX).**
Users build from source (`cd native && cargo build --release`) or
download from GitHub Releases. Only acceptable for an early 0.x release
targeting Dart/Flutter developers comfortable with Rust toolchains.

### Future improvement

Dart's experimental **native assets** feature (RFC in progress) could
automate binary compilation at `dart pub get` time, eliminating the
manual step entirely.

---

## 10. Pre-Publish Verification Checklist

Run these steps for **each package** before `dart pub publish`:

- [ ] `dart pub publish --dry-run` — reports no errors
- [ ] `dart analyze --fatal-infos` — zero issues
- [ ] `dart test` — all tests pass
- [ ] `dart format --output=none --set-exit-if-changed .` — no formatting changes
- [ ] `LICENSE` file present in package root
- [ ] `README.md` file present in package root
- [ ] `CHANGELOG.md` file present in package root
- [ ] `publish_to: 'none'` removed from `pubspec.yaml`
- [ ] Path dependencies replaced with version constraints
- [ ] `description` is 180 characters or fewer
- [ ] `homepage`, `repository`, `issue_tracker` fields set
- [ ] `topics` field set (max 5)
- [ ] Example file present (`example/example.dart`)
- [ ] `flutter: plugin:` block correct (federated `implements`/`default_package`)
- [ ] `dart doc --dry-run` — no warnings

### Automated publish script (`tool/publish.sh`)

The path-to-version swap, publish, and restore cycle should be automated.
Create `tool/publish.sh` with this algorithm:

1. **Pre-flight:** Ensure `git diff --quiet` (clean working tree).
   Abort if uncommitted changes exist.
2. **Read version:** Extract from root `pubspec.yaml`.
3. **Swap path deps to version constraints:** For every `pubspec.yaml`,
   replace `path:` lines pointing to sibling packages with
   `^<version>`. Also remove `publish_to: 'none'`.
4. **Dry-run all packages** in publish order. Abort on any failure:
   1. `packages/dart_monty_platform_interface`
   2. `packages/dart_monty_ffi`
   3. `packages/dart_monty_wasm`
   4. `packages/dart_monty_web`
   5. `packages/dart_monty_native`
   6. `.` (root)
5. **Publish** each package with `dart pub publish --force` in the same
   order. Sleep 15s between each to allow pub.dev indexing.
6. **Restore:** Run `git restore '**/pubspec.yaml'` to revert all
   changes, returning to `path:` deps for local development.
7. **Trap on failure:** If any step fails, restore immediately so the
   working tree is never left in a broken state.

The script replaces the manual checklist items for `publish_to` removal
and path dependency conversion — those happen automatically at publish
time and are reverted immediately after.

---

## 11. Release Automation

### Per-release gate

Every release must ship with updated dartdoc, changelog, and binaries.
A CI workflow (`.github/workflows/prepare-release.yaml`) should enforce
this as a gate before `dart pub publish`.

**Trigger:** Manual dispatch (`workflow_dispatch`) with a `version` input.

**Steps:**

1. Bump `version:` in all 6 `pubspec.yaml` files
2. Verify every package has a `CHANGELOG.md` entry matching the version
3. Run `dart doc --dry-run` in each package — fail on warnings
4. Build native binaries (linux-x64, macos-x64) via `cargo build --release`
5. Copy binaries into `dart_monty_native` platform dirs (if vendoring)
6. Run full test suite (`tool/analyze_packages.py`, `dart test`, `cargo test`)
7. Run `dart pub publish --dry-run` in publish order — fail on errors
8. If all pass, create a git tag and GitHub Release with binaries attached

This can be a single workflow or a `tool/prepare_release.sh` script that
CI calls. The key constraint: **no publish without all gates green**.

### Upstream monty release monitoring

The native Rust crate pins `monty` to a git rev:

```toml
monty = { git = "https://github.com/pydantic/monty.git", rev = "87f8f31" }
```

The WASM JS bridge pins npm packages:

```json
"@pydantic/monty": "^0.0.7",
"@pydantic/monty-wasm32-wasi": "^0.0.7"
```

A scheduled GitHub Action should watch for new upstream releases and
open a PR to test compatibility.

**Workflow:** `.github/workflows/upstream-monty-check.yaml`

```yaml
name: Upstream monty check

on:
  schedule:
    - cron: '0 8 * * 1'   # Weekly on Monday 08:00 UTC
  workflow_dispatch:

jobs:
  check-upstream:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check for new monty releases
        id: check
        run: |
          # Rust crate: latest commit on pydantic/monty main
          LATEST=$(gh api repos/pydantic/monty/commits/main --jq '.sha[:7]')
          CURRENT=$(grep -oP "rev = \"\K[^\"]*" native/Cargo.toml)
          echo "latest=$LATEST" >> "$GITHUB_OUTPUT"
          echo "current=$CURRENT" >> "$GITHUB_OUTPUT"
          if [ "$LATEST" != "$CURRENT" ]; then
            echo "changed=true" >> "$GITHUB_OUTPUT"
          fi

          # NPM: latest version of @pydantic/monty
          NPM_LATEST=$(npm view @pydantic/monty version 2>/dev/null || echo "unknown")
          NPM_CURRENT=$(jq -r '.dependencies["@pydantic/monty"]' packages/dart_monty_wasm/js/package.json | tr -d '^~')
          echo "npm_latest=$NPM_LATEST" >> "$GITHUB_OUTPUT"
          echo "npm_current=$NPM_CURRENT" >> "$GITHUB_OUTPUT"
          if [ "$NPM_LATEST" != "$NPM_CURRENT" ]; then
            echo "npm_changed=true" >> "$GITHUB_OUTPUT"
          fi
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Create PR for Rust update
        if: steps.check.outputs.changed == 'true'
        run: |
          BRANCH="chore/bump-monty-${{ steps.check.outputs.latest }}"
          git checkout -b "$BRANCH"
          sed -i "s/rev = \"${{ steps.check.outputs.current }}\"/rev = \"${{ steps.check.outputs.latest }}\"/" native/Cargo.toml
          git add native/Cargo.toml
          git commit -m "chore(native): bump monty to ${{ steps.check.outputs.latest }}"
          git push -u origin "$BRANCH"
          gh pr create \
            --title "chore(native): bump monty to ${{ steps.check.outputs.latest }}" \
            --body "Upstream monty has new commits. CI will verify compatibility."
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Create PR for NPM update
        if: steps.check.outputs.npm_changed == 'true'
        run: |
          BRANCH="chore/bump-monty-npm-${{ steps.check.outputs.npm_latest }}"
          git checkout -b "$BRANCH"
          cd packages/dart_monty_wasm/js
          npm install "@pydantic/monty@${{ steps.check.outputs.npm_latest }}" \
                      "@pydantic/monty-wasm32-wasi@${{ steps.check.outputs.npm_latest }}"
          cd -
          git add packages/dart_monty_wasm/js/package.json packages/dart_monty_wasm/js/package-lock.json
          git commit -m "chore(wasm): bump @pydantic/monty to ${{ steps.check.outputs.npm_latest }}"
          git push -u origin "$BRANCH"
          gh pr create \
            --title "chore(wasm): bump @pydantic/monty to ${{ steps.check.outputs.npm_latest }}" \
            --body "Upstream @pydantic/monty NPM has a new version. CI will verify compatibility."
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

When CI passes on the auto-generated PR, it signals that a new
dart\_monty release is safe to cut. When CI fails, it surfaces
breaking changes early.

---

## 12. README and Documentation

The current README is written for contributors/maintainers. For pub.dev
it must shift focus to **consumers** — how to install, use, and
understand platform support.

### README updates required

**Replace milestone table with platform support and roadmap.**
External users don't know what M1-M9 means. Replace with:

```markdown
## Platform Support

| Platform | Status |
|----------|--------|
| macOS | Supported |
| Linux | Supported |
| Web (browser) | Supported |
| Windows | Planned |
| iOS | Planned |
| Android | Planned |
```

Link planned items to GitHub Issues so users can track/upvote.

**Add installation section** (currently missing — show
`flutter pub add dart_monty` with a code block).

**Update architecture tree** to show all 6 packages:

```text
dart_monty                           # App-facing API (Flutter plugin)
  dart_monty_platform_interface      # Abstract contract (pure Dart)
  dart_monty_ffi                     # Native FFI bindings (dart:ffi -> Rust)
  dart_monty_wasm                    # WASM bindings (dart:js_interop -> Web Worker)
  dart_monty_native                 # Native plugin (desktop + mobile, Isolate)
  dart_monty_web                     # Web plugin (browser, script injection)
```

**Update license section.** Change from "Private. Not published to
pub.dev." to "MIT License" (matching the LICENSE file from Section 1).

**Move contributor-facing sections** (manual build steps, gate scripts,
CI details) to a new `CONTRIBUTING.md`. Keep the README focused on
usage.

**Add web setup note** about COOP/COEP headers required for
SharedArrayBuffer support.

### PLAN.md

Keep in the repo for contributors but:

- Remove the "When You Resume" section (internal developer note)
- Add to `.pubignore` so it is not uploaded to pub.dev
- Link from README: "See [PLAN.md](PLAN.md) for engineering milestones
  and quality gates."

### .pubignore

Create `.pubignore` in each package root to exclude development files
from the pub.dev upload:

```text
tool/
test/fixtures/
PLAN.md
spike/
native/
.github/
```

### GitHub Issues for roadmap

Create issues for each incomplete milestone so users can track progress:

| Issue title | Milestone |
|-------------|-----------|
| Feature: Complete Flutter web support | M6 |
| Feature: Windows support | M7 |
| Feature: iOS and Android support | M7 |
| Task: Hardening, benchmarks, stress testing | M8 |
| Feature: REPL mode | M9.1 |
| Feature: Type checking | M9.2 |
| Feature: DevTools extension | M9.5 |

Link these from the README roadmap table.

---

## Summary of Files to Create or Modify

| Action | File |
|--------|------|
| Done | ~~Merge `feat/m5-desktop-plugin` branch into `main`~~ (rebased) |
| Done | ~~`LICENSE` (repo root) + copied into 5 package directories~~ |
| Done | ~~`README.md` in each of 5 sub-package directories~~ |
| Done | ~~`CHANGELOG.md` in repo root + each of 5 package directories (6 total)~~ |
| Done | ~~`example/example.dart` in 5 sub-packages + root package~~ |
| Done | ~~`pubspec.yaml` in repo root (add metadata, add missing deps, fix `flutter: plugin: platforms:`)~~ |
| Done | ~~`pubspec.yaml` in 5 sub-packages (add metadata)~~ |
| Done | ~~Add explicit constructors with dartdoc to 4 classes (Section 7)~~ |
| Done | ~~Move `MockMontyPlatform` to `dart_monty_testing.dart` (Section 7)~~ |
| Done | ~~Create barrel files for `dart_monty` and `dart_monty_web` (Section 7)~~ |
| Done | ~~Add `flutter: plugin:` block to `dart_monty_web` pubspec~~ |
| Done | ~~Add `dart_monty_wasm` dep to `dart_monty_web` pubspec~~ |
| Done | ~~Native binary distribution: Option A — vendor binaries in pub.dev upload (Section 9)~~ |
| Done | ~~`tool/publish.sh` — automated path swap, publish, restore (Section 10)~~ |
| Done | ~~`.github/workflows/prepare-release.yaml` — per-release gate (Section 11)~~ |
| Done | ~~`.github/workflows/upstream-monty-check.yaml` — weekly upstream monitor (Section 11)~~ |
| Done | ~~`README.md` — platform table, install section, architecture, license (Section 12)~~ |
| Done | ~~`CONTRIBUTING.md` — move developer/contributor sections from README (Section 12)~~ |
| Done | ~~`.pubignore` in each package root (Section 12)~~ |
| TODO | Remove "When You Resume" section from `PLAN.md` (Section 12) |
| TODO | GitHub Issues for M6, M7, M8, M9 milestones (Section 12) |
