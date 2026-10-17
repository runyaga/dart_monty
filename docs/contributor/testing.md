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

Integration tests use the real core worker. Build or obtain
`dart_monty_worker`, then set `DART_MONTY_WORKER` to its path on the VM.

```bash
DART_MONTY_WORKER=<path>/dart_monty_worker \
  dart test --run-skipped --tags=integration
```

The integration suite lives primarily in `test/integration/`. It exercises
runtime sessions, host functions, extensions, OS access, and worker-backed
execution.

## Run acceptance tests

The acceptance suite drives the package through a worker on the VM and through
web worker assets in browser cells.

```bash
DART_MONTY_WORKER=<path>/dart_monty_worker \
  dart test test/acceptance --run-skipped --tags=acceptance
```

## Run a platform cell

`tool/test_cell.sh CELL` runs three selections for one platform: integration,
acceptance, and portable tests tagged `cell`. It checks pass counts, skipped
counts, participating suites, duplicate test identifiers, and runner output
against `tool/test_floors.tsv`.

```bash
DART_MONTY_WORKER=<path>/dart_monty_worker \
  bash tool/test_cell.sh vm
bash tool/test_cell.sh chrome-dart2js
bash tool/test_cell.sh chrome-dart2wasm
bash tool/test_cell.sh firefox-dart2js
bash tool/test_cell.sh firefox-dart2wasm
```

The VM cell needs `DART_MONTY_WORKER`. Chrome and Firefox cells need their
respective browser executable. Browser cells compile with both `dart2js` and
`dart2wasm`.

## CI test matrix

CI runs the VM cell in the integration job and each browser cell in the
browser-cell job. The worker job supplies the VM worker. The test workflow also
runs the default suite, analysis, formatting, and focused checks.

## Test locations

- `test/` contains unit and shared tests.
- `test/integration/` contains real-worker integration tests.
- `test/acceptance/` contains worker and browser acceptance tests.
- `test/fixtures/` contains shared test data.
- `test/surface/` records the public package surface.
