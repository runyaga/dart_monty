# Testing Guide

The test suite covers package behavior on the VM and in browser compilation
cells. `dart_test.yaml` defines the `integration`, `acceptance`, and `cell`
tags used by the platform runner.

## Run the default suite

```bash
dart test
```

This runs the default VM test selection. Tests tagged `integration` and
`acceptance` are skipped by default.

## Run integration tests

Integration tests use the prebuilt core worker that the build hook installs on
the VM. Native workspace tests also need the root package to opt in to the
worker library:

```yaml
hooks:
  user_defines:
    dart_monty_core:
      build_worker: true
```

```bash
dart test --run-skipped --tags=integration
```

The integration suite lives primarily in `test/integration/`. It exercises
runtime sessions, host functions, extensions, OS access, and worker-backed
execution.

## Run acceptance tests

The acceptance suite drives the package through a worker on the VM and through
web worker assets in browser cells.

```bash
dart test test/acceptance --run-skipped --tags=acceptance
```

## Run a platform cell

`tool/test_cell.sh CELL` runs three selections for one platform: integration,
acceptance, and portable tests tagged `cell`. It checks pass counts, skipped
counts, participating suites, duplicate test identifiers, and runner output
against `tool/test_floors.tsv`.

```bash
bash tool/test_cell.sh vm
```

The supported cells are `vm`, `chrome-dart2js`, `chrome-dart2wasm`,
`firefox-dart2js`, and `firefox-dart2wasm`.

The VM cell uses the prebuilt worker that core's hook installs. Its native
workspace tests also need the root `build_worker: true` opt-in above. Set
`DART_MONTY_WORKER` only to override the executable with a locally built
worker. Chrome and Firefox cells need their respective browser executable.
Browser cells compile with both `dart2js` and `dart2wasm`.

## CI test matrix

CI runs the VM cell in the integration job and each browser cell in the
browser-cell job. Core's build hook supplies the VM worker. The test workflow
also runs the default suite, analysis, formatting, and focused checks.

Test selection follows the directories and tags under `test/`. Look at
`dart_test.yaml`, `tool/test_cell.sh`, and `tool/test_floors.tsv` for the
current suite definitions and platform floors.


## Runtime Pages artifact checks

Run `bash tool/check_demo_pages.sh` with the Dart SDK, the locked documentation
packages (`pip install -r requirements-docs.lock`) and Chrome available. The
command builds MkDocs, compiles every web entry point with explicit package
resolution, copies the resolved core worker, checks links and writes
`build/demo-site/page-manifest.json`. Use `--build-only` to create a review
artifact, or `--smoke-only` to test that assembled artifact without recompiling.

The browser checks every runtime page and catalog example, Reset, sorting Start
for each algorithm, reference navigation and documentation search. It serves
under `/dart_monty/` and clears origin storage before each visit, running both
without COI headers (the Pages service-worker path) and with COI headers.
Evidence is saved under `build/demo-smoke-evidence/`. Missing Chrome exits 77
(or fails with `DEMO_PAGES_STRICT=1`); a skip is not a successful smoke.

`example/web/web/examples.json` owns runnable demo Python, setup keys, page
placement and exact expected values or exception classes. `stagedFiles` names
Dart-provided memory files; `requires` names a prior feed. VM coverage is in
`test/integration/web_examples_test.dart`, using the same filesystem and child
module setup as the browser. Ladder compatibility fixtures remain in
`test/fixtures/python_ladder/`; only explicit native-only and unsupported
`del`/`globals()` forms are skipped. Unexpected failures, value differences and
unexpected passes fail the Pages smoke. Browser outcomes must be measured on
the pinned worker before changing that policy.

Pages builds and smokes on pushes, pull requests and dispatches. Only a
successful main build can deploy, and deployment uses the artifact that passed
smoke. Branch artifacts are downloadable as `pages-review`.
