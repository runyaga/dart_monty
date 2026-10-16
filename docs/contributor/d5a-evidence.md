# D5-A evidence and remaining work

Branch: `d5a/live-children`; base: `2f7befd`. Core pin:
`1bdd9b502e85dd7e17a96736f25346dae48a62b4`.

## Prior implementation evidence

The final implementation audit at `e844465` recorded passing VM witnesses for
child context/isolation, all seven limit fields, admission and retained handles,
origin cancellation, cleanup faults, collection/free ordering, inherited leases,
clone ownership, external waiters, finite pool refusal and OS policy routing.
The facade contains 45 names and 167 declared dm members; eight removed-surface
negative fixtures pass. All 33 runtime and eight surface mutants were killed by
assertion failures. The six D5 contract files compile with dart2js and dart2wasm;
this does not establish browser runtime parity.

The prior analyzer, format, API and core-import checks passed. Changed-file DCM
reported 87 existing test findings; changed library/contract files had none.
The lib and suite ratchets passed; the suite baseline decreased from 137 to 112.
VM batches passed but overlap and must not be summed. VM acceptance recorded
nine passes and three failures because process inspection through pgrep was
denied. The isolated DCM host gate was blocked during dependency fetching.
Raw gate logs remain local under ignored `.gate-logs/`.

## Pending progress for the PR

The resolution manifest retains all **102** discovered identities, including
**96** mapped IDs with executing VM assertions. The full verifier remains red:
six demo IDs lack mappings, and browser execution cells remain missing. The
`d1-pending` mechanism remains in place; no floors were lowered.

The six unmapped IDs are in `test/integration/demo_page_boot_test.dart`, with
prefix `demo example runs and the page renders it as a success ` and suffixes
`example/web/web/agent.html [sandbox]`, `[gather]`, `[output]`, `[lifecycle]`,
`[error]`, and `[childfs]`.

D5-B still owns browser execution, the six demo ports, the 14 D4fs cases in
`workspace_scenarios_test.dart`, and the 16-child / one-module / <=320 MB
measurement harness and validator. Native owned child backing remains D4b.
The earlier handoff gaps file was unreadable under the sandbox; that audit used
the design contracts. No browser execution or full-D5 merge readiness is claimed.

## Review fixes validated on 2026-10-16

- Hygiene commit `d2c647c` removes 128 tracked `.gate-logs/` artifacts from the
  tip while retaining their files locally and ignoring future logs. This file
  replaces the tracked progress transcript with concise PR evidence.
- RED-first commit `93d43b4` adds an admitted-collection write barrier in both
  provider registration orders, plus duplicate-namespace clone disposal counts.
  Before the fixes, both collection tests failed with `provider disposed during
  collection`; clone disposal counts were `[1, 0]` instead of `[1, 1]`.
- Coordinator teardown now waits for owned sandbox transfers and child/workspace
  leases to settle before disposing other owned extensions. Rejected clones are
  tracked before registration and disposed alongside already-owned clones;
  cleanup faults do not replace the original registration/factory error.
- Restoring concurrent provider teardown kills both collection regressions.
  Removing pre-registration clone tracking kills the clone-count regression.
  Both mutations were restored; the focused coordinator/lifecycle/ownership
  run then passed all **71** tests.

All VM runs used the read-only worker at
`<core-checkout>/lib/src/bin/macos-arm64/dart_monty_worker`
via `DART_MONTY_WORKER`. The SDK was invoked directly with
`--suppress-analytics`. Review stdout remains local in `.gate-logs/review-*`.

| Check | Result |
| --- | --- |
| `dart analyze --fatal-infos` | PASS, zero issues. |
| Changed Dart file format check; `git diff --check` | PASS. |
| `dcm analyze` coordinator and the two changed test files | Exit 2: 26 existing coordinator-test findings (21 warning, five style); no findings in the library or lifecycle test. |
| `tool/dcm_ratchet.sh` | PASS: zero lib issues against baseline nine. |
| `tool/dcm_suite_ratchet.sh` | PASS: 112 against baseline 112; no baselines changed. |
| `dart test -p vm --reporter json` | PASS: 829 passed, 50 default skips. |
| `dart test test/integration -p vm --run-skipped --tags integration --exclude-tags 'd1-pending || demo' --reporter json` | 408 passed, 23 failed: 19 HTTP-related failures (proxy HTTP 403, including two missing-result failures) and four example launcher failures. |
| Four example smoke tests rerun with an SDK wrapper on PATH | PASS: all four. The wrapper only invokes the same SDK with analytics suppressed, avoiding Flutter launcher writes denied by the sandbox. The 19 network-related integration failures remain unresolved. |

The focused GREEN command was `dart test -p vm --run-skipped` with
`test/src/bridge/extension_coordinator_test.dart`,
`test/integration/child_lifecycle_test.dart`, and
`test/integration/inherited_extension_ownership_test.dart`.
No browser tests were run for these fixes.
