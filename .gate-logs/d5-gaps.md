# D5 preparation: current-main contract audit and evidence

Base: dm `6406a2da8f55932d2bd1dc3c2e14d5a6bc3c6f8e`.
Core: repository pin `4a4d80d7c65c5f721c47a3e42d36187a271d6ef6`
(`0.110.0-dev.1`). This is preparation, not D5-A/B completion. D4a/F-2,
constructor/caps/workspace changes, floors, baselines and the 96 deferred
D1-8 identities are untouched. All source references below are to this base.

## Step 1: code verdicts and executable preparation coverage

| Item | Current main | New executable IDs and scope |
|---|---|---|
| G2 | Gap in runtime child construction. Coordinator propagation already holds. | `D5-context-coordinator-isolation`: supplied spawn context is passed unchanged to the clone; real separate sessions do not inherit globals/raw registrations; child OS composition honors the execution-specific override. |
| G3 | Selection and reduction logic holds by inspection; actual child checkout/enforcement is blocked. | `D5-omitted-whole-object-precheckout`, `D5-explicit-independent-precheckout`, `D5-guest-reduce-precheckout`: owner fallback, independent explicit limits (including null fields and larger/smaller host caps), lower/equal/zero guest caps, negative/escalating rejection, finite caps on unbounded fields. |
| G6 | Gap in terminal cleanup across resources; coordinator disposal continues after an extension throws. | `D5-dispose-throws-coordinator`: owned child extensions before and after a throwing disposer are each attempted once; parent objects remain undisposed until parent teardown. |
| G7 | Gap for inherited borrowed objects/leases; clone/exclude already holds. | `D5-clone-exclude`: two distinct child clones have distinct owners, exclusion, independent disposal and surviving child/parent calls, one disposal per owned instance. |
| G10 | Finite injected-pool sub-execution and its late-checkout cleanup hold; child/transfer paths blocked. | `D5-finite-subexecute`: real one-slot pool, 100 ms caller timeout, valid 2 s feed limit, actual TimeoutException within budget + 3 s tolerance, root reuse, caller pool reuse after runtime disposal. `D5-timeout-late-close-subexecute`: real execution-handle cancellation with a delayed session through the existing private runtime seam; exactly one close, no feed, no second close on disposal. |
| G11 | Explicit authoritative core route holds; ordinary sandbox child policy is blocked. | `D5-system-child-coordinator`: a manually acquired default-policy session inherits a callback (positive getenv probe), but clock/random bypass it. `D5-direct-authoritative`: public core call_host checkout + MontyBridge returns the custom clock; identical host entropy reproduces random output, changed entropy changes it; exact callback names/counts and closes. |

`-coordinator`, `-precheckout` and `-subexecute` suffixes deliberately distinguish
these preparation cases from the full design's child-runtime assertions. They
must not be entered as replacements for the blocked D5 IDs or any D1-8 ID.
The six required test files contain ten executing tests, no placeholders/skips.
Coordinator witnesses use real worker sessions acquired by the test; the test
owns their close. That is not evidence of sandbox session acquisition/cleanup.

The G3 pre-checkout tests follow existing `child_limit_selection_test.dart`:
accepted requests reach the exact existing `UnimplementedError('D1-8')`;
rejected requests throw ArgumentError before reaching it. They intentionally
assert only validation/selection, never a successful child feed. Once D5-A
implements checkout, replace those stub-boundary assertions with observed
checkout parameters and real child results.

## Gaps D5-A must close (no failing tests added)

| ID(s) | Gap at file:line | Required change/evidence |
|---|---|---|
| G2 / `D5-context-checkout`, `D5-child-subexecute` | `lib/src/extensions/sandbox.dart:548` checkout is a stub; `:451` selects null/legacy cwd; `:577` constructs a bare bridge. | Supply a private runtime-owned checkout closure; capture origin ID/token and effective limits before await; child-local sub-executor using that pool/limits/token; D4a workspace cwd `/work`. Assert exactly one child checkout and separate sub-execution session. |
| G2 / `D5-context-late-checkout` | `lib/src/extensions/sandbox.dart:471` checks only extension disposal; `:493` stores the mutable parent reference rather than origin context. | Invalidate by originating execution/token, close late sessions once without publishing handles, and bind events to the captured origin. |
| G3 / full `D5-omitted-whole-object`, `D5-explicit-independent`, `D5-guest-reduce`, `D5-suspensions`, `D5-total-sleep` | `lib/src/extensions/sandbox.dart:535` already selects the whole object; `:914` already preserves all seven fields; `:548` prevents observing those fields at checkout or enforcement. | Preserve the existing selection/reduction code when wiring checkout. Add seven distinct field assertions, mixed nulls, unchanged fields after reductions, same effective limits in child subExecute, real suspension/sleep failures and successful fresh children. Do not claim dropped-field or three-field mutants are killed by this preparation. |
| G6 / `D5-parent-crash`, `D5-child-crash`, `D5-cancel-origin` | `lib/src/extensions/sandbox.dart:496` handle has no originating execution/token; `:493` forwards only the parent reference. | Bind descendants to origin, cancel on origin failure/cancellation, preserve retained handles on successful root completion, isolate siblings with other origins, settle once without guest replay. |
| G6 / full `D5-attach-seed-failure`, `D5-dispose-throws`, `D5-free-race`, `D5-late-checkout` | `lib/src/extensions/sandbox.dart:157`, `:473`, `:595`, `:716` perform sequential cleanup that can skip later resources when one throws. | One idempotent cleanup future; independently attempt stream cancellation, bridge/session close, owned-extension disposal and D4a backing/admission release; lease ordering and exactly-once settlement, including partial attach/seed failures. Coordinator-only disposal evidence does not establish this. |
| G6 / `D5-stream-error-no-done` | `lib/src/extensions/sandbox.dart:753` marks failed/settles but does not initiate cleanup. | Start/join cleanup immediately on stream error without depending on onDone. Add no-done barrier and independent-close mutants. |
| G2/G6 admission portion | `lib/src/extensions/sandbox.dart:518` counts only alive handles; `:496` publishes after awaits. | Reserve synchronously for pending/live/retained handles, release exactly once after free/disposal or unpublished failure. Actual reservation/workspace tests remain gated on D4a. |
| G7 / `D5-borrow-two-children` | `lib/src/extension/coordinator.dart:434` registers the inherited parent instance as ordinary child-owned state; `:165` overwrites canonical owner; `:51` overwrites logger; `:379` disposes every registered object. | Track owned clones vs borrowed inherited objects with leases. Do not rebind/dispose borrowed objects on child teardown; retain child-local call context; parent waits for leases before one final owned disposal. Borrowed rebind/dispose mutants remain blocked. |
| G10 / `D5-finite-child`, child `D5-timeout-late-close` | `lib/src/extensions/sandbox.dart:548` cannot reach the runtime pool. | Route through the private pool closure with the caller's finite timeout; no detached timeout wrapper, pool introspection or transport fallback. Repeat the one-slot refusal and cancellation/late-close witnesses through sandbox_spawn. Existing subExecute limit/close behavior is at `lib/src/runtime/runtime.dart:441`. |
| G10 / `D5-finite-transfer` | `lib/src/extensions/sandbox.dart:548` plus the absent D4a transfer implementation. | D4a owns transfer-side acquisition. Repeat its finite caller-pool precondition after D4a; do not introduce a transfer API in preparation. Document that omitted finite timeout is unsupported for bounded injected-pool acquisition. Preserve dm's 30 s owned-pool configuration at `lib/src/runtime/runtime.dart:131` and `:221`. |
| G11 / full `D5-system-child` | `lib/src/extensions/sandbox.dart:548` has no implemented ordinary child checkout. | Use default System policy when implementing ordinary child checkout, even with inherited callbacks. Run the inherited-callback witness through actual sandbox_spawn. Forwarding an authoritative policy into that ordinary checkout cannot be mutated/tested yet. Keep authoritative execution explicitly core checkout + MontyBridge. |

## Executed validation

- VM: **10/10 passed**, zero skips; `DART_MONTY_WORKER=/private/tmp/claude-501/w/dart_monty_worker`, Dart 3.13.5.
- All six test files compile to **dart2js and dart2wasm (12/12)**, explicitly using `--packages=.dart_tool/package_config.json`. Compilation is not browser runtime evidence.
- Chrome runtime attempts: process launch failed with exit 1 in this sandbox, on both compilers. No browser test passes are claimed. The host commands below remain required.
- Additional existing acceptance suite: **9/12 passed**. A7(a) and the two A9 process-accounting cases error because `pgrep` cannot query the sandbox's process list (`sysmon ... sysmond service not found`). No acceptance assertion or floor was changed.
- `dart analyze --fatal-infos`: no issues. `dcm analyze` on the seven added Dart files: no issues. `dart format --output=none --set-exit-if-changed` on them: zero changes.
- CI adds a D5 preparation browser step beside D3, with Chrome/Firefox × dart2js/dart2wasm and the existing integration tag. No d1-pending exclusion is applied to these new cases.
- Dependency setup initially found stale ignored resolution at core `5976598`. A temporary local override to the cached **exact declared 4a4d80 commit** allowed offline resolution. The override was removed, and `dart pub get --offline --no-example` then successfully restored the declared git dependency at 4a4d80. No dependency declaration/pin change is committed.

## Mutation evidence

Each mutation changed the indicated existing `lib/` code locally, ran exactly
the named new test with JSON reporting, and restored the original bytes in a
`finally` block. All 14 exited 1 with a discovered executing test failure/error,
not a compilation or discovery failure. Every new test has at least one kill.
`git diff --exit-code -- lib` passes after restoration.

| Mutant | New test ID | Red observation |
|---|---|---|
| CONTEXT-DROP-OVERRIDE | D5-context-coordinator-isolation | Child sees parent OS value instead of execution override. |
| LIMIT-DROP-OWNER | D5-omitted-whole-object-precheckout | Owner-cap escalation reaches checkout instead of ArgumentError. |
| LIMIT-PREFER-OWNER | D5-explicit-independent-precheckout | Independent larger child caps are incorrectly rejected. |
| LIMIT-MERGE-NULLS | D5-explicit-independent-precheckout | Explicit unbounded fields incorrectly fall back to owner caps. |
| LIMIT-ALLOW-ESCALATION | D5-guest-reduce-precheckout | Escalation reaches checkout instead of ArgumentError. |
| LIMIT-ALLOW-NEGATIVE | D5-guest-reduce-precheckout | Negative guest cap reaches checkout instead of ArgumentError. |
| DISPOSE-STOP-ON-ERROR | D5-dispose-throws-coordinator | Later owned extension receives zero disposal attempts. |
| CLONE-REGISTER-PARENT | D5-clone-exclude | Child coordinator owns parent instead of the fresh clone. |
| EXCLUDE-REGISTER-PARENT | D5-clone-exclude | Excluded function appears in child's schemas. |
| SUB-REUSE-ROOT | D5-finite-subexecute | Sub-execution succeeds instead of timing out on the second checkout. |
| POOL-CLOSE-BORROWED | D5-finite-subexecute | Reuse raises `the monty pool is closed`. |
| SUB-DROP-LATE-CLOSE | D5-timeout-late-close-subexecute | Late session receives zero closes. |
| OS-DROP-INHERITED-CALLBACK | D5-system-child-coordinator | Positive inheritance probe records zero callbacks. |
| OS-DROP-BRIDGE-HANDLER | D5-direct-authoritative | call_host feed ends in error instead of the custom clock/random result. |

Raw local evidence: `.gate-logs/d5-vm.jsonl`, `d5-acceptance-vm.jsonl`,
`d5-compilation.json`, `d5-analyze.log`, `d5-dcm.log`, `d5-format.log`, and
`.gate-logs/d5-mutants/{results.json,<mutant>.jsonl}`. The repeatable local
mutation driver is `.gate-logs/d5-mutate.py`. These generated logs are not part
of the source commit; this report records the results and limitations.

## Host browser commands

Run from this clone after normal dependency resolution:

```bash
files=(
  test/integration/child_context_test.dart
  test/integration/child_limits_test.dart
  test/integration/child_lifecycle_test.dart
  test/integration/inherited_extension_ownership_test.dart
  test/integration/injected_pool_timeout_test.dart
  test/integration/child_os_policy_test.dart
)
mkdir -p build/d5-cells
for compiler in dart2js dart2wasm; do
  dart test -p chrome -c "$compiler" --run-skipped --tags integration \
    --reporter json "${files[@]}" > "build/d5-cells/chrome-$compiler.jsonl" || exit $?
done
# Same neighbouring CI matrix (requires Firefox as well):
MOZ_HEADLESS=1 dart test -p chrome,firefox -c dart2js,dart2wasm \
  --run-skipped --tags integration "${files[@]}"
# Existing acceptance evidence, independently of preparation:
MOZ_HEADLESS=1 dart test test/acceptance -p chrome,firefox -c dart2js,dart2wasm \
  --run-skipped --tags acceptance
```

For the VM new-test batch, use the same files array with
`DART_MONTY_WORKER=/private/tmp/claude-501/w/dart_monty_worker dart test -p vm --run-skipped --tags integration --reporter json "${files[@]}"`.
