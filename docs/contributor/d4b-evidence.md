# D4b native workspace implementation and resume evidence

Validated on 2026-10-16 on `d4b/native-disk`, based on dm `2f7befd` (D4a
included). Core remains pinned to `1bdd9b502e85dd7e17a96736f25346dae48a62b4`.
The read-only `../d4-core` checkout is clean at that pin.

The interrupted run left five commits (`f5803d6` through `f816cb7`), eleven
modified files, and an untracked CI configuration helper. `.gate-logs` did not
exist. Old mutation logs and browser compile outputs survived under `build/`;
they were not treated as current passing evidence. The recovered changes were
reviewed, corrected, tested, and committed in `cf97fa9`. Every subsequent step
was committed with explicit paths.

The first fresh native run exposed an incorrect N6 test expectation: core
cancellation raises StateError, not MontyError. Correcting that expectation
retains checks that the execution stops, its mount rejects reuse, and owned
backing is removed despite a throwing session close. Two further regressions
were demonstrated red before their fixes:

- `423a3e2` / `e9a6930`: repeated native traversal roots must charge every
  occurrence, including empty directories; a deduplicated snapshot map cannot
  serve as the traversal counter.
- `044463b` / `30d4f7d`: read-only destination refusal must happen before
  checkout. With a held finite pool, the old adapter incorrectly timed out.

## Requirement audit

| Requirement | Implementation / executable evidence | Result |
| --- | --- | --- |
| Owned native backing; virtual `/work`; VM-only imports | `lib/src/workspace/disk_backing{,_io,_stub}.dart`; `workspace.dart`; `native_workspace_refusal_test.dart` | Fresh package-owned directory, read-write MountDir, constructor cleanup, web refusal; both web compilers succeed. |
| Public-snapshot policy interception before mount dispatch | `workspace_driver.dart`; `N2-intercept-before-mount` | Real mount write refused with the required PermissionError; backing unchanged. No deleted handler restored and no core implementation imports. |
| Function/future/name dispatch, sleeps, prints and errors | `N1-snapshot-composition`, `N5-sleep-budget`, `N-print-error-frames` | Three callbacks overlap behind a barrier, complete 60/100/140, return request order; sync/async sleeps charged by core once; automatic/manual print and error-frame parity. |
| Retention, repeated collection, retry and both disposal orderings | `N3-native-lifecycle`, `N3-native-lifecycle-retry`, `N4-dispose-lease` | Execution session closes before two successful collections; second-destination failure preserves sources; lease winner settles before deletion; disposal winner prevents writes. |
| Independent cleanup and backing aliases | `N6-independent-cleanup`, `N7-backing-aliases` | Throwing cleanup does not prevent later cleanup; active execution mount closes; symlink components and a symlink inside a renamed directory refuse before mutation. |
| D4a lifetime caps and read-only policy on disk | `native_workspace_policy_test.dart` reuses all 17 cap cases; driver read-only matrix | Seed/current content plus 64 bytes per entry; lifetime writes, deletion without refund, rejection atomicity, rename/overwrite accounting, all covered read-only mutations. |
| Transfer byte/entry/depth/path bounds, serialization and release | Shared 11 bounds cases on native backing; `B-native-*` cases | Exact boundaries, aggregate/repeated-source charging, bounded host reads/listings, selected-source staging, symlink refusal, failed-copy cleanup and retry. The 4,096-byte path boundary uses a memory destination because host path limits may be lower. |
| Persistent adapter and finite acquisition | `persistent_transfer.dart`; `T-native-persistent-parent-cwd`, `T-native-overlay-and-read-only-adapters`, `D4a-transfer-capacity` | Captured persistent namespace, absolute paths across changed cwd, separate sessions with finite execution/acquisition limits, overlay refusal and read-only write refusal before checkout. No unbounded native read callback is exposed. |
| Fifteen disk parity scenarios | `P-01-read` through `P-15-open-exclusive` | Private driver matches core feedRun over the same upstream native mount implementation. This is not a fresh external Python-oracle run. |
| Real native library and fake-session compatibility | Full native suite and `N-fake-native-mount`; artifact hashes below | Both real worker sessions and FakeMontySession touch real disk through the delivered mount library. Missing delivery fails construction. |
| Hook configuration and CI artifact consumption | `.github/workflows/ci.yaml`, `tool/configure_native_ci.py`, `tool/record_native_asset.py` | Reuses D4a worker/library artifact installation; root opts into build_worker; exact IDs and mutant kills are required; both delivered artifacts and the actual hook JIT asset are fingerprinted and uploaded. Linux workflow execution remains outstanding. |
| Facade and D5 boundary | Exact surface/member tests; minimal `sandbox.dart` selection and independent cleanup changes | Facade remains 51 names and 184 retained dm member signatures. No child-checkout implementation, floor, baseline, deferred manifest or gate.sh change. Live children remain D5. |

## Gates and artifact identity

The machine-readable [evidence](d4b-evidence.json) records every captured gate
command, exit code, elapsed time, registered test name/result, stdout hash,
red-first regression and all 21 mutation results. Raw stdout remains in the
ignored `.gate-logs/` directory and `build/d4b-mutations/`. The test manifest
validator requires exact IDs, successful completion and no skipped native
cases; the manifest is an identity inventory, not a lowered numeric floor.

| Gate | Result |
| --- | --- |
| Native driver suite | 48/48 passed; includes N1–N7 and 15 disk parity cases. |
| Shared cap/bounds suite on native backing | 28/28 passed; every workspace's owned directory removed after each case. |
| Portable workspace regression group on VM | 252/252 passed, including migration, transfers, caps, bounds and write modes. |
| Unit bridge / other source groups | 227 + 201 passed; 49 existing deferred child cases remain skipped. |
| Facade compiler suite, four short shards | 133/133 passed: kernel/js/wasm positive imports and 130 negative fixtures. |
| Facade behavior | 2/2 passed. |
| Remaining VM integration/experiment groups, eight short runs | 381 passed; 19 failed because HTTP is blocked by proxy 403, including downstream missing-result failures. No browser boot test was run. |
| VM A1–A9 | Nine passed; A7's process-count assertion and both A9 process-cleanup checks fail because pgrep cannot obtain the sandbox process list. |
| Mutations | 21/21 killed by runtime failures; source restored after every mutant. Includes the ten shared BOUNDS mutants on native backing. Serialization uses a two-second overlap barrier; early-delete produces its expected assertion failure and a bounded teardown timeout. |
| `dart analyze --fatal-infos` | PASS, zero issues. |
| `dart format --output=none --set-exit-if-changed .`; diff whitespace check | PASS. |
| `dart doc --validate-links .` | PASS. |
| DCM library ratchet | PASS: zero findings against unchanged baseline 9. |
| DCM suite ratchet | PASS: 137 findings against unchanged baseline 137. |
| `dcm analyze .` | Exit 2, 49 existing non-library findings (34 warnings, 15 style); ratchets above are the enforced gates. |
| Isolated DCM host gate | BLOCKED before analysis: dart pub get fails in its detached worktree. Resolved-checkout ratchets above ran on the host. |
| API-exercised | PASS: all 27 public entry points exercised, zero baseline exceptions. |
| Core reference agreement; no core src imports; SDK pin | PASS. |
| Workflow validity and action pins | PASS; actionlint validates all six workflows. |
| Workflow-token check | BLOCKED: PyYAML unavailable; attempted installation could not resolve the package. |
| Web compilation | PASS: native-refusal test and all five portable workspace test files compile with both js and wasm, using explicit package configuration. |
| CI helper fixtures | PASS: hook opt-in, matching artifacts, mismatch refusal, JIT asset fingerprint and missing-asset refusal. These fixtures do not substitute for Linux CI execution. |

Local VM commands use
`DART_MONTY_WORKER=/private/tmp/claude-501/w6/dart_monty_worker` and core's
package-relative mount-library lookup. The root hook is not enabled locally,
so no build writes were attempted in the read-only core checkout. CI explicitly
enables the hook and requires its emitted asset in addition to the package
fallback artifacts.

| Artifact | SHA-256 |
| --- | --- |
| `/private/tmp/claude-501/w6/dart_monty_worker` | `c31a22aff61405817ed0438fee871783e950d656a605d0ca89cf538264522b50` |
| `../d4-core/lib/src/bin/macos-arm64/libdart_monty_worker.dylib` | `c7b0765684686bf15bd0c8b656db4b341a72f15a3617db783adb2311d322aaf4` |

The installed Dart SDK was invoked directly with analytics suppressed, a
writable TMPDIR and CommandLineTools git. Each gate wrapper has a 55-second
wall-clock limit; compile fixtures were split into four shards. Each mutation
has a five-second test timeout and a 60-second subprocess bound. No browsers
were launched, no acceptance assertions were weakened, and no floors or
baselines were changed.

## Remaining gaps and exact browser commands

This checkout is not represented as fully merge-green. Browser runtime evidence
is absent by explicit user instruction. The 19 HTTP integration failures,
three process-inspection acceptance failures, isolated DCM resolution, workflow
token dependencies and actual Linux hook-enabled CI execution remain open.
The browser commands below are mandatory follow-up evidence, not completed
checks. Live child admission/checkout and end-to-end child scenarios belong to
D5; D4b proves the backing helper independently.

Run from the repository root in an environment permitted to launch browsers:

```bash
mkdir -p build/d4b-web
for browser in chrome firefox; do
  for compiler in dart2js dart2wasm; do
    MOZ_HEADLESS=1 dart test -p "$browser" -c "$compiler" \
      --run-skipped --reporter=json \
      test/integration/native_workspace_refusal_test.dart \
      > "build/d4b-web/$browser-$compiler.jsonl"
    python3 tool/verify_d4b_tests.py browser \
      "build/d4b-web/$browser-$compiler.jsonl"

    MOZ_HEADLESS=1 dart test -p "$browser" -c "$compiler" \
      --run-skipped --reporter=json \
      test/integration/workspace_migration_test.dart \
      test/integration/workspace_transfer_test.dart \
      test/src/workspace/caps_test.dart \
      test/src/workspace/bounds_test.dart \
      test/src/workspace/write_modes_test.dart

    MOZ_HEADLESS=1 dart test -p "$browser" -c "$compiler" \
      --run-skipped --tags=acceptance --reporter=json \
      test/acceptance/agent_loop_test.dart
  done
done
```

## Native workspace review follow-up

Validated on 2026-10-16 against dm `5875b2859bd26c460f00b66bf560a1f949f01bd6`.
The preceding sections retain the earlier run's evidence. This follow-up uses
`DART_MONTY_WORKER=<core-checkout>/lib/src/bin/macos-arm64/dart_monty_worker`.
Core was read-only throughout; no core implementation or dependency pin changed.

Native read-only checks now compare both the requested path and protected roots
using Dart's `String.toLowerCase()`, including ancestor and descendant checks.
This rule applies on every host filesystem, even a case-sensitive volume, before
native mutation dispatch. Both the driver and persistent transfer adapter use
it, including rename destinations. Memory workspace paths retain their existing
case-sensitive policy. The rule is deliberately conservative: native workspaces
cannot mutate a differently cased spelling of a protected path even when the
host would treat it as a distinct entry.

Cleanup validates the recorded canonical root and every ancestor without
following links, and checks each visited directory's resolved path. It lists
children with `followLinks: false` and deletes individual entries and empty
directories nonrecursively. A changed root or ancestor reports an `OSError`
identifying the recorded backing path; cleanup leaves that backing for host
recovery instead of following a replacement path. Tests cover a changed parent
pointing to a separate tree, a parent pointing to the relocated original tree,
and a replaced root. Validation is repeated before each deletion; these tests
exercise settled namespace changes, not concurrent host renames between system
calls.

Nonempty payload writes use the existing bounded persistent transfer pool so
the driver can observe the native operation's result before resuming Python.
The pool permits one worker and uses finite checkout/request deadlines. A failed
operation releases its write reservation; retained content is still reconciled
from disk. Python may catch the operation's error and write again in the same
feed. A successful write remains charged when later Python code fails, and
identical successful writes and deletions retain lifetime-budget semantics.
This adds transfer-session work to payload writes; it does not use a new core
API or import `dart:io` into portable workspace code.

| Check | Result |
| --- | --- |
| N8 policy regressions, before fix | 11 failed. |
| N9 cleanup regressions, before fix | 3 failed. |
| N10 accounting regressions, before fix | 2 failed; the successful-write control passed. |
| Final N8–N10 regression file | 17 passed. |
| Updated native CI command and exact-ID manifest | 65 passed; all 17 review cases included. |
| Native driver/policy/review plus portable workspace integration and unit tests | 345 passed. |
| Default `dart test -p vm` | 772 passed; 101 configured skips. |
| Review mutation checks | 3/3 killed by runtime test failures; sources restored, then all 17 review tests passed. |
| `dart analyze --fatal-infos` | Zero issues. |
| `dcm analyze` on all five changed Dart files | Zero issues. |
| Changed Dart format check and diff whitespace check | Passed. |
| Native-refusal and portable workspace migration tests, JS and Wasm compilation | Passed with explicit `--packages=.dart_tool/package_config.json`; no browser execution. |

The `native_review` object in [machine-readable evidence](d4b-evidence.json)
records commands, results, artifact identity and log hashes. Raw logs are in
ignored `build/native-review/` and `build/d4b-mutations/`. Reproduce the new
mutation checks with:

```bash
python3 tool/d4b_mutations.py --only D4b-REVIEW
```

## Native identity and metrics follow-up

Validated on 2026-10-16 with the same read-only core checkout and worker path
above. This supersedes the preceding case-folding-only policy and cleanup
identity description.

Native protection compares path components only when their case-folded,
canonically normalized spellings are equal. The private normalizer has
compose/decompose tables for the common Latin-1 Supplement and Latin
Extended-A/B diacritics and reorders U+0300--U+036F combining marks. This
blocks both NFC/NFD directions for writes, truncating open, rename source and
destination, mkdir, unlink and protected descendants without treating an
unrelated non-ASCII component as a wildcard. It therefore permits `output.txt`
beside protected `café`, `résumé.txt` beside `config.txt`, and distinct
`café`/`cafè` siblings. Memory policy remains spelling-based.

When two native components do not match that table, the backing also probes
whether their existing host paths resolve to the same file before dispatch.
That catches aliases the host recognizes in scripts outside the table. The
residual limit is explicit: unlisted scripts rely on that host-identity probe;
if the alias path does not yet resolve to the protected host entry, only the
Latin normalizer can establish equivalence.

The owned directory now contains a private `.owner` token and a mounted `work`
subdirectory. The random 256-bit token never enters the guest namespace or its
memory accounting. Cleanup verifies the token before deleting entries, retains
it until data deletion finishes, then removes the marker and empty container.
Replacing either the base or owned directory with an ordinary directory and a
same-length incorrect token refuses cleanup, preserves both original and
replacement contents, and reports the recorded backing path. Existing symlink
checks remain. This protects against settled replacements; path-based checks
are not atomic against concurrent host renames between system calls.

`WorkspaceDriver._resumeDisk` delegates preflight to `_preflightDisk`, and
`PersistentTransfer.call` delegates mount policy to `_checkWritable`. Both files
now have zero DCM metric findings. No baseline or threshold changed.

| Check | Result |
| --- | --- |
| Initial regressions against original code | 15 Unicode and 2 cleanup cases failed. |
| Final identity regression file | 21 passed. |
| Native CI exact-ID manifest | 83 registered and passed. |
| Native and portable workspace suites | 363 passed. |
| Default VM suite | 772 passed; 102 configured skips. |
| New identity mutants | 2/2 killed by runtime failures. |
| Existing review mutants | 3/3 killed; sources restored and native suite rerun. |
| Dart analysis and DCM lint | Zero issues. |
| Direct DCM suite comparison | 137 findings vs 137; metrics 16 vs 16; no new files or rule increases. |
| Workspace migration JS and Wasm compilation | Passed with explicit package configuration. |
| Workflow validation | Passed. |

The host gate remains for the host to run. Local ratchet wrappers could not
create their temporary files in the sandbox. All eight DCM commands ran directly;
the suite's unchanged comparison code accepted the seven suite JSON reports.
Browser execution and the earlier unrelated full-gate limitations remain as
recorded above. The `native_identity_review` object in the accompanying JSON
records local logs and hashes. Reproduce the two new mutation checks with
`python3 tool/d4b_mutations.py --only D4b-IDENTITY`.
