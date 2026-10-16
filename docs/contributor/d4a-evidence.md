# D4a implementation and resume evidence

Validated on 2026-10-16 in `d4a/workspace-repin`, based on dm `e7da021`.
Core is pinned to `1bdd9b502e85dd7e17a96736f25346dae48a62b4`. The local,
ignored override resolves to the clean, read-only `../d4-core` checkout at that
commit. VM runs use
`DART_MONTY_WORKER=<core-checkout>/lib/src/bin/macos-arm64/dart_monty_worker`.

The resumed clone contained `c0f6802` (red-first tests), `45c9d11` (atomic
repin/removal/implementation), and `db48dda` (evidence hardening). There was no
`.gate-logs` directory. The only uncommitted edit wrapped a test string; it was
preserved in `6317383`. Prior mutation artifacts survived under `build/`.
The initial red-test commit precedes implementation, but its execution log did
not survive. Fresh validation and an additional red-first regression are
recorded below.

Resume fixes normalize negative-fixture diagnostic paths, preflight every
collected destination descendant for symlinks before any writes, correct the
retained-child documentation, and finish formatting. Native overlay evidence
now runs while a real parent feed is suspended. Every step was committed with
explicit paths.

## Requirement audit

Line references identify implementation or executable evidence in this PR.

| Requirement | File:line | Result |
| --- | --- | --- |
| Atomic five-reference core repin, including demo assets | `pubspec.yaml:64`; `.github/workflows/pages.yaml`; `example/{,native/,web/}pubspec.yaml`; `example/web/web/*.html` | PASS: five refs agree; no old pin remains in tracked source/docs. |
| Nine filesystem names and implementations removed; no package:file | `lib/dart_monty.dart:17`; `test/surface/negative_cases.json:1`; `pubspec.yaml:16` | PASS: 51 facade names on native/browser, 184 retained dm member signatures, 42 dm declarations; six D5 child names retained. |
| Final M6 dependency surface | `test/public_surface_test.dart:71`; `test/surface/core-m6-names.json:1` | PASS: exactly 68 main names on both platforms. |
| Private workspace, copy-in/collection and cap accounting | `lib/src/workspace/workspace.dart:14`; `lib/src/workspace/workspace.dart:110`; `lib/src/workspace/workspace_transfers.dart:89` | PASS: OSAccess/MemoryFile composition, UTF-8 payloads, 64 bytes per entry, finite defaults, explicit null, rejection atomicity, lifetime accounting. |
| Transfer ceilings, captured parent, leases and retry | `lib/src/workspace/workspace_transfers.dart:3`; `lib/src/workspace/workspace_transfers.dart:129`; `test/src/workspace/bounds_test.dart:18` | PASS: byte/entry/depth/path bounds, aliases, symlink refusal, staged reads, serialized transfers, disposal ordering and retry. |
| Descendant destination symlink refusal | `lib/src/workspace/workspace_transfers.dart:167`; `test/src/workspace/bounds_test.dart:181` | RED in `60b3366`, GREEN after `a0e99c2`; restoring the omission kills `BOUNDS-DESTINATION-LINK`. |
| Sandbox signature/schema and cwd | `lib/src/extensions/sandbox.dart:196`; `lib/src/extensions/sandbox.dart:342`; `lib/src/bridge/session_bridge.dart:153` | PASS: files/ro_files/collect, final cap fields, `/work`; constructor/member fixtures pass. |
| All 17 transferred cap IDs and routing cases | `test/src/workspace/caps_test.dart:19`; `test/integration/workspace_migration_test.dart:18` | PASS against real core sessions. |
| Required workspace transfers and T1/T2/T4/T5 | `test/integration/workspace_transfer_test.dart:24`; `test/integration/_workspace_overlay_io.dart:9` | PASS on VM. Native T2 proves a fresh mount table loses suspended overlay state, both transfers reject without the live adapter, and the parent resumes unchanged. |
| Portable web test source | `test/integration/_workspace_harness.dart:5`; `test/integration/_workspace_overlay_web.dart:7` | All five workspace test files compile with dart2js and dart2wasm. Browser helper explicitly tests host-mount refusal. Browser execution remains unrun by instruction. |
| D4b/D5 boundary | `lib/src/extensions/sandbox.dart:377`; `lib/src/extensions/sandbox.dart:622`; `docs/deep-dives/oscall-vfs.md:75` | Native backing is documented pending D4b; child checkout remains the D1-8 stub for D5. |
| Floors, acceptance and deferred exclusions preserved | `.github/workflows/ci.yaml:388`; `.github/workflows/ci.yaml:492`; `tool/gate.sh:368`; `dart_test.yaml:15` | No diff to floors, gate.sh, acceptance files or d1-pending configuration. |

## Gate results

Full discovered case names, pass/fail/skip results, commands, stdout hashes and
all 30 mutant results are in [d4a-evidence.json](d4a-evidence.json). Raw stdout is
retained locally in `build/d4a-resume/` and `build/d4a-mutations/`. The supplied
design compile runner and its inputs were copied byte-for-byte under
`build/d4a-fixtures/` because its temporary-file creation cannot run inside the
read-only design directory.

| Gate | Result |
| --- | --- |
| `dart analyze --fatal-infos` | PASS, zero issues. |
| Formatting all 40 changed Dart files; `git diff --check` | PASS. Formatting reports an unresolved analysis-options include in the web example's existing package configuration; no file needs formatting. |
| `dcm analyze` changed files | Exit 2: 141 findings (86 warnings, 55 style), all outside lib. The new platform overlay helpers separately report zero issues. |
| `bash tool/dcm_host_gate.sh` | BLOCKED: its detached worktree's pub get tries GitHub and receives CONNECT HTTP 403. It does not reach analysis. |
| `bash tool/dcm_ratchet.sh` against the local resolved checkout | PASS: zero lib issues against baseline 9. |
| `bash tool/dcm_suite_ratchet.sh` against the local resolved checkout | PASS: 137 findings against baseline 137. |
| `bash tool/check_core_ref.sh` | PASS, all five files at the new pin. |
| `bash tool/check_api_exercised.sh` | PASS, all 27 public entry points exercised; zero baseline exceptions. |
| `bash tool/check_no_core_src_imports.sh` | PASS. |
| `rg -n 'resolveOpenCall\|package:file/\|ChildVfsStrategy' lib pubspec.yaml` | PASS: exit 1, no matches. |
| Unit suite, split into four source groups and four compile-fixture shards | 772 passed; eight existing default skips. Above the unchanged 700 floor. |
| VM integration, seven short groups, `--tags=integration --run-skipped --exclude-tags=d1-pending` | 403 passed, 19 failed due to HTTP 403 from `demo.toughserv.com` (including two downstream missing-result failures). Above the unchanged 312 floor, but the suite is not green. |
| Five real-core workspace test files | 230 passed, zero skipped. Includes all 17 cap IDs, routing, transfers, bounds and 180 write-mode combinations. |
| `COMPILE(D4a)` | PASS: positive controls/member/sandbox fixtures plus 130 rejected negative cases. |
| Facade compiler suite | PASS: 130 negative cases plus positive kernel/js/wasm fixtures. Included in the unit total. |
| Workspace test compilation | PASS: all five files with both js and wasm compilers. No browsers launched. |
| VM A1-A9 acceptance | Nine passed, three failed because pgrep cannot obtain the sandbox process list. Failures are A7 cancellation's process-count check and both A9 process-cleanup checks. Tests are unchanged. |
| Mutants | 30/30 killed by assertion failures, not compiler failures; source restored after each. |

The inherited `tool/dcm-suite-baseline.json` change is a **pure decrease** from
156 to 137. Every per-file/per-rule count was checked to be nonincreasing.
`bash tool/dcm_suite_ratchet.sh --update` was rerun during the resume and produced
the identical file. No other baseline changed; `tool/api-exercised-baseline.txt`
is unchanged.

The installed SDK was invoked directly, with analytics suppressed, to avoid
Flutter launcher writes outside this sandbox. Homebrew Bash supplies mapfile;
GNU mktemp respects the writable TMPDIR. DCM ran with the existing local seat,
without CI=true. No credentials were added or changed.

## Remaining validation and planned work

The network-blocked integration cases, three process-inspection acceptance
cases, and isolated DCM host gate need a rerun in an environment permitting
those operations. Browser execution was explicitly prohibited for this task.
Compilation does not establish browser runtime parity.

The design names `D4a-transfer-capacity` under G10. That case remains unverified:
this memory implementation has no native separate-session transfer adapter.
It needs closure when that adapter is supplied; the report does not claim a
finite acquisition bound for arbitrary injected callbacks. Native backing
and bounded reads remain pending D4b. Live child admission/execution remains
D5; this PR does not claim
the 14 end-to-end D4fs child scenarios or release-on-completion mutant coverage.

Exact browser commands to run later from this checkout:

```bash
dart test -p chrome -c dart2js --run-skipped --reporter=json \
  test/integration/workspace_migration_test.dart \
  test/integration/workspace_transfer_test.dart \
  test/src/workspace/caps_test.dart test/src/workspace/bounds_test.dart \
  test/src/workspace/write_modes_test.dart

dart test -p chrome -c dart2wasm --run-skipped --reporter=json \
  test/integration/workspace_migration_test.dart \
  test/integration/workspace_transfer_test.dart \
  test/src/workspace/caps_test.dart test/src/workspace/bounds_test.dart \
  test/src/workspace/write_modes_test.dart

dart test test/acceptance -p chrome,firefox -c dart2js,dart2wasm \
  --run-skipped --tags=acceptance --exclude-tags=d1-pending --reporter=json
```
