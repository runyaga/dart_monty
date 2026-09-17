#!/usr/bin/env bash
# =============================================================================
# DCM suite ratchet — every DCM check, baselined, blocking
# =============================================================================
# Measured 2026-09-15 on this repo: `dcm analyze` was the ONLY DCM check that
# could fail the gate. Five more ran as `run_advisory` (report, never fail) and
# two were not run at all. The unenforced total was 244:
#
#     calculate-metrics                 29      advisory
#     check-parameters                  45      advisory
#     check-unused-code                  7      advisory
#     check-dependencies                 6      advisory
#     check-unused-files                 3      advisory
#     check-exports-completeness         4      NOT RUN
#     check-unnecessarily-public-code  150      NOT RUN
#
# An advisory check is a check whose output nobody reads twice. This ratchets
# them instead: a new rule, a per-rule increase, a new file, or a per-file
# increase fails. Reducing is always allowed and never required -- but an
# improvement must be CAPTURED, or the count drifts back up while green.
#
# `dcm analyze` keeps its own script (tool/dcm_ratchet.sh) and its own baseline.
# This covers everything else, under one baseline keyed by command.
#
# Usage: bash tool/dcm_suite_ratchet.sh [--update]
# Baseline: tool/dcm-suite-baseline.json
# =============================================================================
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
BASELINE=tool/dcm-suite-baseline.json
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

# The commands this ratchet owns, as "subcommand:target".
CHECKS=(
  "calculate-metrics:lib"
  "check-unused-code:lib"
  "check-unused-files:lib"
  "check-dependencies:."
  "check-parameters:lib"
  "check-exports-completeness:lib"
  "check-unnecessarily-public-code:lib"
)

# THE BASELINE A PR IS MEASURED AGAINST MUST NOT BE ONE THE PR CAN EDIT.
# `--update` rewrites it and exits 0, so a lowered baseline committed next to
# the regression it excuses would pass. Reading the comparison copy from the
# base branch means a PR cannot lower its own bar.
if [ -n "${RATCHET_BASE_REF:-}" ] && [ "$UPDATE" = "0" ]; then
  if ! git rev-parse --verify --quiet "${RATCHET_BASE_REF}^{commit}" >/dev/null; then
    echo "FAIL: RATCHET_BASE_REF=${RATCHET_BASE_REF} does not resolve."
    echo "  Refusing to fall back to the working copy: that would measure the PR"
    echo "  against itself and report PASS."
    exit 1
  fi
  BASE_COPY="$(mktemp)"
  if git show "${RATCHET_BASE_REF}:${BASELINE}" > "$BASE_COPY" 2>/dev/null; then
    echo "note: comparing against ${RATCHET_BASE_REF}:${BASELINE}, not the working copy."
    BASELINE="$BASE_COPY"
  else
    rm -f "$BASE_COPY"
    echo "note: no ${BASELINE} on ${RATCHET_BASE_REF} -- this PR introduces it."
  fi
fi

if ! command -v dcm >/dev/null 2>&1; then
  if [ "${DCM_SUITE_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm not installed — SKIPPING (DCM_SUITE_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: dcm is not installed, so the suite ratchet cannot run."
  echo "  Install:  brew tap CQLabs/dcm && brew install dcm"
  echo "  dcm is NOT a pub package. To skip deliberately:"
  echo "    DCM_SUITE_ALLOW_MISSING=1 bash tool/dcm_suite_ratchet.sh"
  exit 1
fi

# DCM IS COMMERCIAL, and a missing licence is a first-class outcome rather than
# an edge case. Without this check the run reaches dcm, gets no JSON, and the
# real reason -- "DCM is not activated" -- ends up buried in a stderr tail.
# dcm only consults the credentials when it believes it is on CI, so CI=true is
# set ALONGSIDE them, not instead of them.
# LOCAL ACTIVATION IS THE PRIMARY PATH; CI CREDENTIALS ARE THE FALLBACK.
#
# `dcm activate --license-key=...` registers a SEAT on this machine, and an
# activated dcm needs no CI key, no email and no CI=true. The GitHub CI path is
# not supported by this project, so demanding those credentials refused the only
# path that is. Measured 2026-09-17 on an activated host, with DCM_CI_KEY,
# DCM_EMAIL and CI all explicitly unset: this script exited 1 while
# `dcm analyze lib --reporter=json` ran normally.
#
# Order matters: the CI key carries a MONTHLY RUN BUDGET and dies with "CI key
# limit for this month has been exceeded"; a seat does not. Preferring the seat
# spends the budget only when there is no seat.
#
# Ported from dart_monty_core 2e03bc2, where the same guard blocked the same
# path.
dcm_activated() { dcm license 2>/dev/null | grep -q '^DCM License:'; }

if ! dcm_activated && { [ -z "${DCM_CI_KEY:-}" ] || [ -z "${DCM_EMAIL:-}" ]; }; then
  if [ "${DCM_SUITE_ALLOW_MISSING:-0}" = "1" ]; then
    echo "DCM credentials absent — SKIPPING (DCM_SUITE_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: dcm is not activated here and no CI credentials are set."
  echo "  PREFERRED — activate a seat on this machine:"
  echo "    dcm activate --license-key=\$DCM_KEY   # DCM_KEY lives in ~/dev/.env"
  echo "  export DCM_CI_KEY=...   # the CI key, NOT a license-key"
  echo "  export DCM_EMAIL=...    # the purchase email"
  echo "  To run the gate without a licence, skipping this deliberately and"
  echo "  knowing it then checks nothing:"
  # NAME THE UMBRELLA, NOT THIS SCRIPT'S OWN VARIABLE. The gate runs TWO dcm
  # ratchets and DCM_SUITE_ALLOW_MISSING skips only this one, so the remedy
  # printed here used to leave the gate failing on the other. Measured with a
  # dcm shim that reports "not activated", credentials unset:
  #
  #   DCM_SUITE_ALLOW_MISSING=1 bash tool/gate.sh -> GATE: FAILED (dcm ratchet)
  #   DCM_ALLOW_MISSING=1       bash tool/gate.sh -> GATE: PASSED, 4 skipped
  #
  # gate.sh exports both specific names when DCM_ALLOW_MISSING is set, so the
  # umbrella is the only spelling that does what this sentence promises.
  # DCM_SUITE_ALLOW_MISSING is still honoured, and is still the right thing to
  # print for a DIRECT invocation of this script -- see the branch above.
  echo "    DCM_ALLOW_MISSING=1 bash tool/gate.sh"
  exit 1
fi

HAVE_V=$(dcm --version 2>&1 | tr -d '\r' | awk '{print $NF}')
WANT_V=$(python3 -c "import json;print(json.load(open('tool/dcm-suite-baseline.json')).get('_dcm_version',''))" 2>/dev/null)
# `--update` MUST BE EXEMPT or the pin deadlocks: the mismatch message tells you
# to regenerate, and regeneration is the thing being refused. Measured on the
# 1.37.0 -> 1.39.0 bump -- `--update` printed the same mismatch and changed
# nothing, so the baseline could never be moved forward.
if [ "$UPDATE" = "0" ] && [ -n "$WANT_V" ] && [ "$HAVE_V" != "$WANT_V" ]; then
  echo "FAIL: dcm version mismatch — baseline was generated by $WANT_V, this is $HAVE_V."
  echo "  Counts are not comparable across versions. Install $WANT_V, or bump and"
  echo "  regenerate in the same commit: bash tool/dcm_suite_ratchet.sh --update"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# Auth shape decided once, outside the loop: an activated seat needs neither
# CI=true nor the credential flags, and passing empty ones makes dcm look for a
# licence it does not need.
DCM_ENV=(); DCM_AUTH=()
if [ -n "${DCM_CI_KEY:-}" ] && [ -n "${DCM_EMAIL:-}" ]; then
  DCM_ENV=(env CI=true)
  DCM_AUTH=(--ci-key="$DCM_CI_KEY" --email="$DCM_EMAIL")
fi

for spec in "${CHECKS[@]}"; do
  cmd="${spec%%:*}"; tgt="${spec##*:}"
  "${DCM_ENV[@]}" dcm "$cmd" "$tgt" --reporter=json "${DCM_AUTH[@]}" \
    > "$WORK/$cmd.json" 2>"$WORK/$cmd.err"
  if [ ! -s "$WORK/$cmd.json" ] || ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$WORK/$cmd.json" 2>/dev/null; then
    echo "FAIL: \`dcm $cmd $tgt --reporter=json\` produced no parseable JSON."
    echo "  This is the gate failing to RUN, which is not the gate passing."
    echo "  --- stderr ---"
    head -10 "$WORK/$cmd.err" | sed 's/^/    /'
    exit 1
  fi
done

WORK="$WORK" BASELINE="$BASELINE" UPDATE="$UPDATE" HAVE_V="$HAVE_V" \
CHECKS="${CHECKS[*]}" python3 - <<'PY'
import json, os, sys, collections, glob

work = os.environ['WORK']
baseline_path = os.environ['BASELINE']
update = os.environ['UPDATE'] == '1'

def count(path):
    """Issues per rule-id and per file, for any DCM json shape."""
    d = json.load(open(path))
    rules, files = collections.Counter(), collections.Counter()
    for value in d.values():
        if not isinstance(value, list):
            continue
        for rec in value:
            if not isinstance(rec, dict) or 'issues' not in rec:
                continue
            p = rec.get('path', '?').split('dart_monty/')[-1]
            for iss in rec['issues']:
                rules[iss.get('id', '?')] += 1
                files[p] += 1
    return rules, files

current = {'_dcm_version': os.environ['HAVE_V'], 'checks': {}}
for f in sorted(glob.glob(f'{work}/*.json')):
    cmd = os.path.basename(f)[:-5]
    rules, files = count(f)
    current['checks'][cmd] = {
        'total': sum(rules.values()),
        'by_rule': dict(rules),
        'by_file': dict(files),
    }

grand = sum(c['total'] for c in current['checks'].values())

if update:
    current['_grand_total'] = grand
    json.dump(current, open(baseline_path, 'w'), indent=2, sort_keys=True)
    print(f"baseline updated: {grand} finding(s) across "
          f"{len(current['checks'])} check(s)")
    for cmd, c in sorted(current['checks'].items()):
        print(f"  {c['total']:>4}  {cmd}")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print(f"FAIL: no baseline at {baseline_path} — run: "
          f"bash tool/dcm_suite_ratchet.sh --update")
    sys.exit(1)

base = json.load(open(baseline_path))
bchecks = base.get('checks', {})

# A BASELINE THAT LIES IS WORSE THAN A HIGH ONE, because the gate agrees with
# it. Verified per-check, not just on the grand total.
for cmd, c in sorted(bchecks.items()):
    if c['total'] != sum(c['by_rule'].values()):
        print(f"FATAL: {baseline_path} is inconsistent for {cmd} -- total "
              f"{c['total']} but by_rule sums to {sum(c['by_rule'].values())}. "
              f"Regenerate: bash tool/dcm_suite_ratchet.sh --update")
        sys.exit(2)

violations = []
for cmd, c in sorted(current['checks'].items()):
    b = bchecks.get(cmd)
    if b is None:
        violations.append(f"NEW CHECK       {cmd}: {c['total']} finding(s) "
                          f"(not in baseline)")
        continue
    for rule, n in sorted(c['by_rule'].items()):
        prev = b['by_rule'].get(rule, 0)
        if prev == 0:
            violations.append(f"NEW RULE        {cmd} / {rule}: {n}")
        elif n > prev:
            violations.append(f"RULE INCREASE   {cmd} / {rule}: {prev} -> {n}")
    for path, n in sorted(c['by_file'].items()):
        prev = b['by_file'].get(path, 0)
        if prev == 0:
            violations.append(f"NEW FILE        {cmd} / {path}: {n}")
        elif n > prev:
            violations.append(f"FILE INCREASE   {cmd} / {path}: {prev} -> {n}")

bgrand = sum(c['total'] for c in bchecks.values())
print(f"dcm suite: {grand} finding(s) vs baseline {bgrand}")
for cmd, c in sorted(current['checks'].items()):
    prev = bchecks.get(cmd, {}).get('total', 0)
    flag = '' if c['total'] == prev else f"   <-- was {prev}"
    print(f"  {c['total']:>4}  {cmd}{flag}")

if violations:
    print(f"\nFAIL — {len(violations)} ratchet violation(s):")
    for v in violations:
        print(f"  {v}")
    print("\nFix them, or if intentional: bash tool/dcm_suite_ratchet.sh --update")
    sys.exit(1)

# A RATCHET THAT ONLY CLICKS ONE WAY IS NOT A RATCHET.
if grand < bgrand:
    print(f"\nFAIL — {bgrand - grand} fewer finding(s) than baseline, and the "
          f"baseline was not updated.")
    print("  An improvement has to be recorded or it is not held: the count can")
    print("  drift straight back to the old number with this gate still green.")
    print("  Capture it:  bash tool/dcm_suite_ratchet.sh --update")
    sys.exit(1)

print("PASS — no new DCM findings above baseline")
PY
