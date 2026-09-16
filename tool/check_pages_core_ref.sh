#!/usr/bin/env bash
# =============================================================================
# The Pages build and the package must use the SAME dart_monty_core ref
# =============================================================================
# .github/workflows/pages.yaml checks out dart_monty_core to compile the demos.
# pubspec.yaml's dependency_overrides names the ref the package is developed
# and tested against. Nothing compared them, and they drifted: pages.yaml sat
# on `main` while the package moved to 0.23. main is 315 commits behind
# integration/0.23 and has ZERO occurrences of `asStringMap`, so the Pages job
# was compiling against a core that could not satisfy the package.
#
# The failure mode is what makes this worth a gate: Pages keeps serving the
# LAST GOOD BUILD, so a broken build reads as "the site is stale" rather than
# "the site cannot be rebuilt". The last success was 2026-06-02.
#
# Same shape as tool/check_version_pin.sh: two copies of one fact, one of them
# unread until it is wrong.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

PAGES=.github/workflows/pages.yaml
PUBSPEC=pubspec.yaml

pages_ref=$(awk '/repository: runyaga\/dart_monty_core/,/path: dart_monty_core/' "$PAGES" \
  | sed -nE 's/^[[:space:]]*ref:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -1)
pub_ref=$(awk '/^dependency_overrides:/,0' "$PUBSPEC" \
  | sed -nE 's/^[[:space:]]*ref:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -1)

if [ -z "$pages_ref" ]; then
  echo "FAIL: could not read the dart_monty_core ref out of $PAGES."
  echo "  A gate that cannot find the thing it compares is not passing, it is broken."
  exit 1
fi
if [ -z "$pub_ref" ]; then
  echo "FAIL: could not read the dart_monty_core ref out of $PUBSPEC dependency_overrides."
  exit 1
fi

if [ "$pages_ref" != "$pub_ref" ]; then
  echo "FAIL: dart_monty_core ref drift."
  echo "    $PAGES   -> $pages_ref"
  echo "    $PUBSPEC (dependency_overrides) -> $pub_ref"
  echo "  The Pages job would compile the demos against a different core than the"
  echo "  package is tested against. Pages serves the last good build on failure,"
  echo "  so this shows up as a stale site, not a red build."
  exit 1
fi

echo "PASS — pages.yaml and pubspec.yaml both use dart_monty_core ref '$pages_ref'"
