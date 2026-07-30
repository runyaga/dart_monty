#!/usr/bin/env bash
# =============================================================================
# DCM ratchet — fail on any NEW issue above the recorded baseline
# =============================================================================
# `dcm analyze` has been chronically red, which makes it
# useless as an upgrade gate: 5 new issues move the count 9 -> 14 and nobody
# notices, and *fixing* 10 old issues masks new ones behind a net improvement.
#
# This ratchets instead: any new rule, any per-rule increase, or any new file
# with issues fails. Reducing counts is always allowed and never required.
#
# Usage: bash tool/dcm_ratchet.sh [path/to/baseline.json]
# Baseline default: tool/dcm-baseline.json  (regenerate with --update)
# =============================================================================
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
BASELINE="${1:-tool/dcm-baseline.json}"
if [ "${1:-}" = "--update" ]; then BASELINE=tool/dcm-baseline.json; UPDATE=1; else UPDATE=0; fi

# A gate that silently skips is not a gate. Skipping is allowed ONLY when the
# caller opts in explicitly (local runs on a machine without dcm); anywhere the
# ratchet is relied upon — CI above all — a missing dcm must FAIL, because the
# alternative is a green tick that checked nothing.
if ! command -v dcm >/dev/null 2>&1; then
  if [ "${DCM_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm not installed — SKIPPING (DCM_RATCHET_ALLOW_MISSING=1)"
    exit 0
  fi
  echo "FAIL: dcm is not installed, so the ratchet cannot run."
  echo "  Install:  brew tap CQLabs/dcm && brew install dcm"
  echo "  Note dcm is NOT a pub package — 'dart pub global activate dcm' does"
  echo "  not work. To skip deliberately on a machine without it:"
  echo "    DCM_RATCHET_ALLOW_MISSING=1 bash tool/dcm_ratchet.sh"
  exit 1
fi

TMP=$(mktemp)
dcm analyze lib --reporter=json > "$TMP" 2>/dev/null

BASELINE="$BASELINE" UPDATE="$UPDATE" TMP="$TMP" python3 - <<'PY'
import json, os, sys, collections

tmp = os.environ['TMP']
baseline_path = os.environ['BASELINE']
update = os.environ['UPDATE'] == '1'

d = json.load(open(tmp))
rules, files = collections.Counter(), collections.Counter()
for r in d['analyzeResults']:
    for iss in r.get('issues', []):
        rules[iss['id']] += 1
        files[r['path']] += 1
current = {'total': sum(rules.values()), 'by_rule': dict(rules), 'by_file': dict(files)}

if update:
    json.dump(current, open(baseline_path, 'w'), indent=2, sort_keys=True)
    print(f"baseline updated: {current['total']} issues, {len(rules)} rules, {len(files)} files")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print(f"FAIL: no baseline at {baseline_path} — run: bash tool/dcm_ratchet.sh --update")
    sys.exit(1)

base = json.load(open(baseline_path))
bt, br, bf = base['total'], base['by_rule'], base['by_file']
violations = []

for rule, n in sorted(rules.items()):
    prev = br.get(rule, 0)
    if prev == 0:
        violations.append(f"NEW RULE      {rule}: {n} issue(s)")
    elif n > prev:
        violations.append(f"RULE INCREASE {rule}: {prev} -> {n}")

for path, n in sorted(files.items()):
    prev = bf.get(path, 0)
    if prev == 0:
        violations.append(f"NEW FILE      {path}: {n} issue(s)")
    elif n > prev:
        violations.append(f"FILE INCREASE {path}: {prev} -> {n}")

print(f"dcm: {current['total']} issues vs baseline {bt}  "
      f"({len(rules)} rules / {len(files)} files vs {len(br)} / {len(bf)})")

if violations:
    print(f"\nFAIL — {len(violations)} ratchet violation(s):")
    for v in violations:
        print(f"  {v}")
    print("\nFix them, or if intentional: bash tool/dcm_ratchet.sh --update")
    sys.exit(1)

if current['total'] < bt:
    print(f"PASS — and {bt - current['total']} fewer than baseline. "
          f"Consider: bash tool/dcm_ratchet.sh --update")
else:
    print("PASS — no new issues above baseline")
PY
rc=$?
rm -f "$TMP"
exit $rc
