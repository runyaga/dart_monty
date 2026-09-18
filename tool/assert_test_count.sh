#!/usr/bin/env bash
# =============================================================================
# tool/assert_test_count.sh — a floor under a `dart test` run
# =============================================================================
# A suite that registers ZERO tests prints success and exits 0. This repo has
# already paid for that shape once (8dbdd59, "The test returned, asserted
# nothing, and reported PASSING. 646 of 1593 registered tests took one of those
# paths"). Anywhere a test invocation feeds something downstream — a coverage
# tracefile, a gate, a published number — "it passed" is not enough; the count
# has to be checked.
#
# Usage:
#   dart test ... 2>&1 | tee run.log
#   bash tool/assert_test_count.sh run.log 400 "unit"
#
# WHY THIS IS A SCRIPT AND NOT A ONE-LINE grep. `dart test` picks its reporter
# from the environment, and the reporters do not agree on how to print the
# count. Measured on CI run 34828230428: the inline `grep -oE '\+[0-9]+'` that
# works locally found NOTHING on GitHub Actions, because `dart test` auto-selects
# the `github` reporter there and that reporter prints
#
#     🎉 457 tests passed.
#
# with no `+N` anywhere in the log. The assertion read the count as 0 and failed
# a green 457-test run. Which is the right direction to fail in — but it is
# still wrong, and a gate that fails for the wrong reason gets deleted.
#
# So: both shapes, and NO count parsed at all is a failure with its own message,
# never a silent zero.
# =============================================================================
set -uo pipefail

LOG="${1:-}"
MIN="${2:-}"
LABEL="${3:-test}"

if [ -z "$LOG" ] || [ -z "$MIN" ]; then
  echo "FAIL: usage: bash tool/assert_test_count.sh LOG MIN [LABEL]"
  exit 2
fi
if [ ! -s "$LOG" ]; then
  echo "FAIL: $LABEL test log '$LOG' is missing or empty."
  echo "  The run produced no output at all, which is not a passing run."
  exit 1
fi

# `github` reporter: "🎉 457 tests passed." / "N tests passed, M failed."
N=$(grep -oE '[0-9]+ tests? passed' "$LOG" | tail -1 | grep -oE '^[0-9]+')
# `compact` / `expanded` reporters: "00:05 +457: All tests passed!"
if [ -z "$N" ]; then
  N=$(grep -oE '\+[0-9]+' "$LOG" | tail -1 | tr -d '+')
fi

if [ -z "$N" ]; then
  echo "FAIL: could not read a test count out of $LABEL log '$LOG'."
  echo "  Neither 'N tests passed' (github reporter) nor '+N' (compact and"
  echo "  expanded reporters) appears in it. A reporter this script does not"
  echo "  know about is a reason to teach it one, not to assume zero."
  echo "  --- last 10 lines ---"
  tail -10 "$LOG" | sed 's/^/    /'
  exit 1
fi

echo "$LABEL tests run: $N (floor $MIN)"
if [ "$N" -lt "$MIN" ]; then
  echo "FAIL: expected at least $MIN $LABEL tests, saw $N."
  echo "  A suite that registers nothing prints success and exits 0. Raise this"
  echo "  floor when the suite grows; never lower it to make a run pass."
  exit 1
fi
