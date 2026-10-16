# Developer Setup

Everything needed to build, test, and contribute to dart\_monty. The package has no Rust or native code of its own. The worker, native library and Web Worker assets come from `dart_monty_core`.

## Required Tools

### Dart SDK

Required for all packages (pure Dart).

```bash
# macOS
brew install dart-sdk
# or via Flutter (includes Dart)
brew install --cask flutter
```

Verify: `dart --version` (>= 3.10)

### Flutter SDK (optional)

Only needed for Flutter-specific integration tests. All dart_monty packages
are pure Dart and do not require Flutter.

```bash
brew install --cask flutter
```

Verify: `flutter --version`

### Python 3

Used for developer scripts and linting tools.

```bash
brew install python@3.12
```

Verify: `python3 --version` (>= 3.12)

### pre-commit

Git hook framework that runs linters on every commit.

```bash
pip install pre-commit
# or
brew install pre-commit

# Install hooks in this repo
pre-commit install
```

Verify: `pre-commit --version`

## Linting and Analysis Tools

### pymarkdown

Python-based markdown linter (not markdownlint-cli from npm).

```bash
pip install pymarkdownlnt
```

Verify: `pymarkdown --version`

Usage:

```bash
pymarkdown \
  --set extensions.front-matter.enabled=\$!True \
  --disable-rules MD013,MD024,MD033,MD036,MD041,MD060 \
  scan **/*.md
```

### gitleaks

Secret scanning tool — runs in pre-commit and CI.

```bash
brew install gitleaks
```

Verify: `gitleaks version`

### DCM (Dart Code Metrics)

Commercial Dart analysis tool. Optional for local development
(CI handles it), but useful for deeper analysis.

```bash
# See https://dcm.dev/docs/getting-started/installation/
brew tap nicklockwood/formulae
brew install dcm
```

Verify: `dcm --version`

## LSP / Editor Setup

### Dart / Flutter

- **VS Code:** Install the [Dart](https://marketplace.visualstudio.com/items?itemName=Dart-Code.dart-code)
  and [Flutter](https://marketplace.visualstudio.com/items?itemName=Dart-Code.flutter)
  extensions. The Dart Analysis Server starts automatically.
- **Neovim / other:** Use `dart language-server` or `analysis_server`.

## Quick Verification

After installing everything, run these from the repo root:

```bash
dart pub get
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The integration and acceptance suites need a worker. On the VM, build
`dart_monty_worker` with `dart_monty_core`'s `tool/build_worker.sh` and point
`DART_MONTY_WORKER` at it. In a browser, the suites use `dart_monty_core`'s
committed Web Worker assets and need Chrome or Firefox.

```bash
DART_MONTY_WORKER=<path>/dart_monty_worker \
  bash tool/test_cell.sh vm
bash tool/test_cell.sh chrome-dart2js
```

`tool/test_cell.sh` takes one of `vm`, `chrome-dart2js`, `chrome-dart2wasm`,
`firefox-dart2js` and `firefox-dart2wasm`. It runs the integration and
acceptance suites for that cell and fails when fewer tests ran than the floor
in `tool/test_floors.tsv`.

## Tool Summary

| Tool | Version | Purpose |
|------|---------|---------|
| Dart SDK | >= 3.10 (CI pins 3.13.5) | Compilation, analysis, tests |
| Flutter SDK | optional | Flutter-specific integration tests |
| Chrome | current | Browser cells (`chrome-dart2js`, `chrome-dart2wasm`) |
| Firefox | current | Browser cells (`firefox-dart2js`, `firefox-dart2wasm`) |
| Python 3 | >= 3.12 | Developer scripts, linting |
| pre-commit | any | Git hook automation |
| pymarkdown | any | Markdown linting |
| gitleaks | any | Secret scanning |
| DCM | any | Dart code metrics (optional locally) |
