#!/usr/bin/env bash
# tool/test_cell.sh CELL [DART_TEST_ARG...]
#
# Runs the integration, acceptance and portable (tag `cell`) suites for one
# platform cell and checks each against its recorded floor in tool/test_floors.tsv. Cells:
#   vm | chrome-dart2js | chrome-dart2wasm | firefox-dart2js | firefox-dart2wasm
#
# A cell fails when dart test fails, when fewer tests ran than the floor,
# when more tests were skipped than the recorded allowance, when fewer suite
# files loaded than the minimum, when two tests share a suite and name, or when the run printed no result at all.
# Extra arguments go to both dart test invocations.
set -uo pipefail

cell="${1:-}"
[ -n "$cell" ] || { echo "usage: tool/test_cell.sh CELL [DART_TEST_ARG...]" >&2; exit 2; }
shift
root="$(cd "$(dirname "$0")/.." && pwd)"
floors="$root/tool/test_floors.tsv"

case "$cell" in
  vm) platform=(-p vm) ;;
  chrome-dart2js) platform=(-p chrome -c dart2js) ;;
  chrome-dart2wasm) platform=(-p chrome -c dart2wasm) ;;
  firefox-dart2js) platform=(-p firefox -c dart2js) ;;
  firefox-dart2wasm) platform=(-p firefox -c dart2wasm) ;;
  *) echo "FAIL: unknown cell '$cell'" >&2; exit 2 ;;
esac
case "$cell" in
  chrome-*) [ -n "${CHROME_EXECUTABLE:-}" ] || command -v google-chrome >/dev/null 2>&1 || [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] || { echo "FAIL: no Chrome executable for $cell" >&2; exit 1; } ;;
  firefox-*) [ -n "${FIREFOX_EXECUTABLE:-}" ] || command -v firefox >/dev/null 2>&1 || [ -x "/Applications/Firefox.app/Contents/MacOS/firefox" ] || { echo "FAIL: no Firefox executable for $cell" >&2; exit 1; } ;;
esac

out="$(mktemp -d)"
trap '/bin/rm -rf "$out"' EXIT
status=0

for suite in integration acceptance portable; do
  floor="$(awk -F'\t' -v c="$cell" -v s="$suite" '$1==c && $2==s {print $3}' "$floors")"
  allow="$(awk -F'\t' -v c="$cell" -v s="$suite" '$1==c && $2==s {print $4}' "$floors")"
  nsuites="$(awk -F'\t' -v c="$cell" -v s="$suite" '$1==c && $2==s {print $5}' "$floors")"
  if [ -z "$floor" ] || [ -z "$allow" ] || [ -z "$nsuites" ]; then
    echo "FAIL: no floor for $cell/$suite in tool/test_floors.tsv"
    status=1
    continue
  fi
  case "$suite" in
    integration) select=(--tags integration) ;;
    acceptance) select=(test/acceptance --tags acceptance) ;;
    portable) select=(--tags cell) ;;
  esac
  log="$out/$suite.jsonl"
  dart test "${platform[@]}" "${select[@]}" --run-skipped --reporter json "$@" >"$log" 2>"$out/$suite.err"
  rc=$?
  python3 -I - "$log" "$floor" "$allow" "$cell/$suite" "$rc" "$nsuites" <<'PY' || status=1
import json, sys
log, floor, allow, label, rc, min_suites = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5]), int(sys.argv[6])
suites, tests, seen, dups = {}, {}, set(), []
passed = skipped = failed = 0
done_ok = None
for line in open(log, errors="replace"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    t = e.get("type")
    if t == "suite":
        suites[e["suite"]["id"]] = e["suite"].get("path", "")
    elif t == "testStart":
        tests[e["test"]["id"]] = e["test"]
    elif t == "testDone" and not e.get("hidden"):
        test = tests.get(e["testID"], {})
        key = (suites.get(test.get("suiteID"), ""), test.get("name", ""))
        if key in seen:
            dups.append(key)
        seen.add(key)
        if e.get("skipped"):
            skipped += 1
        elif e.get("result") == "success":
            passed += 1
        else:
            failed += 1
    elif t == "done":
        done_ok = e.get("success")
print(f"{label}: {passed} passed, {skipped} skipped, {failed} failed, {len(set(suites.values()))} suites (floor {floor}, skips allowed {allow}, suites at least {min_suites})")
errs = []
if rc != 0:
    errs.append(f"dart test exited {rc}")
if done_ok is None:
    errs.append("no done event in the report")
if done_ok is False:
    errs.append("the done event reports failure")
if len(set(suites.values())) < min_suites:
    errs.append(f"{len(set(suites.values()))} suites is under the minimum of {min_suites}")
if failed:
    errs.append(f"{failed} failing tests")
if passed < floor:
    errs.append(f"{passed} passed is under the floor of {floor}")
if skipped > allow:
    errs.append(f"{skipped} skipped is over the allowance of {allow}")
if dups:
    errs.append("duplicate ids: " + "; ".join(f"{s}: {n}" for s, n in dups[:5]))
for m in errs:
    print("FAIL: " + m)
sys.exit(1 if errs else 0)
PY
  if [ "$rc" -ne 0 ]; then tail -n 40 "$out/$suite.err" 2>/dev/null; fi
done
exit "$status"
