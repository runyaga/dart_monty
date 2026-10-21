# Developer Setup

Everything needed to build, test, and contribute to dart_monty. The package
contains Dart sources. The `dart_monty_core` dependency supplies web worker
assets and its build hook installs the verified prebuilt VM worker. The mount
library for `MountDir` needs the root package opt-in.

## Required tools

### Dart SDK

Contributors require Dart SDK 3.11 or later.

```bash
brew install dart-sdk
dart --version
```

### Python 3

Python runs repository scripts and documentation tooling.

```bash
brew install python@3.12
python3 --version
```

### Browsers

Chrome runs the Chrome cells. Firefox runs the Firefox cells. The cell runner
uses `CHROME_EXECUTABLE` or `FIREFOX_EXECUTABLE` when set, then searches the
platform defaults.

## Repository layout

The repository root separates package sources, tests, examples,
documentation, and development tools. Look at `pubspec.yaml` for the SDK and
dependency constraints and at `tool/` for the commands used by CI.

## Install dependencies

Run this from the repository root.

```bash
dart pub get
bash tool/resolve_packages.sh
```

## Quick verification

```bash
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The default test run skips slow integration and acceptance tests. The VM cell
uses the prebuilt worker that core's hook installs. Browser cells use web
worker assets from the resolved core package.

```bash
bash tool/test_cell.sh vm
bash tool/test_cell.sh chrome-dart2js
```

Look at `tool/test_floors.tsv` for the supported platform cell names and their
expected suite counts.

To test an unreleased core commit, point `dependency_overrides` at that commit,
run core's `tool/build_worker.sh`, and set `DART_MONTY_WORKER` for JIT tests.
The `build_worker: true` opt-in builds the worker library for self-relaunch. If
the bundled manifest has a target, the hook uses its listed release artifacts.
If the manifest has no target, the opt-in builds only the library from source.
A failed artifact download fails the build. The mount library needs the same
opt-in.
