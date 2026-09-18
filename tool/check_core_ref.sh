#!/usr/bin/env bash
# =============================================================================
# Every dart_monty_core ref in this repo must name the SAME thing
# =============================================================================
# DISCOVERED, NOT ENUMERATED. The predecessor of this script compared exactly
# two files -- .github/workflows/pages.yaml and the root pubspec.yaml -- and so
# passed on a tree where example/pubspec.yaml pinned a THIRD, 197 commits
# behind. It was written against the instance in front of me rather than the
# class, and the class promptly produced another instance.
#
# Measured 2026-09-16, PR #449: CI's `Example smoke tests` failed with
#   lib/src/runtime/value_x.dart:68: The getter 'asStringMap' isn't defined
#   for the type 'MontyDict'
#     - 'MontyDict' is from '.../dart_monty_core-ccdf2812.../...'
# and ccdf2812 is exactly origin/feat/monty-019-p1a.
#
# example/pubspec.yaml needs its own override BY DESIGN -- its own comment says
# "dependency_overrides do NOT propagate from the parent package" -- so the
# second copy cannot be removed. It can only be kept honest.
#
# So: find every file that names a dart_monty_core git ref, and require
# agreement. A seventh copy added later is covered without anyone updating
# this script.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# Any tracked yaml that mentions the repo AND a ref. `git ls-files` keeps
# gitignored per-developer files (pubspec_overrides.yaml) out of it -- those are
# local path overrides by design and are not part of the shared contract.
mapfile -t FILES < <(git ls-files '*.yaml' '*.yml' | xargs grep -l "dart_monty_core" 2>/dev/null)

declare -a NAMES REFS
for f in "${FILES[@]}"; do
  # The ref line nearest after a dart_monty_core mention. COMMENT LINES DO NOT
  # COUNT against the window: a 6-line window missed pages.yaml, whose `ref:`
  # sits 10 lines below `repository:` because a 9-line explanatory comment is
  # wedged between them. A guard that silently inspects 2 of 3 files is the
  # same defect it was written to fix, so the window is generous and blank or
  # commented lines are skipped rather than consuming it.
  r=$(awk '
    /dart_monty_core/ {c=40; next}
    c && /^[[:space:]]*(#|$)/ {next}
    c && /^[[:space:]]*ref:[[:space:]]*/ {
      sub(/^[[:space:]]*ref:[[:space:]]*/,""); sub(/[[:space:]]*$/,""); print; exit
    }
    c {c--}' "$f")
  [ -n "$r" ] && { NAMES+=("$f"); REFS+=("$r"); }
done

if [ "${#REFS[@]}" -eq 0 ]; then
  echo "FAIL: found no dart_monty_core ref in any tracked yaml."
  echo "  A gate that cannot find what it compares is broken, not passing."
  exit 1
fi

first="${REFS[0]}"; bad=0
for i in "${!REFS[@]}"; do
  [ "${REFS[$i]}" = "$first" ] || bad=1
done

if [ "$bad" = "1" ]; then
  echo "FAIL: dart_monty_core ref drift across ${#REFS[@]} file(s)."
  for i in "${!REFS[@]}"; do printf '    %-44s -> %s\n' "${NAMES[$i]}" "${REFS[$i]}"; done
  echo "  These must agree. A stale one compiles this package against a core that"
  echo "  cannot satisfy it -- and for example/ that is invisible to the local"
  echo "  gate, which never resolves example/pubspec.yaml."
  exit 1
fi

echo "PASS — ${#REFS[@]} file(s) all name dart_monty_core ref '$first'"
for i in "${!REFS[@]}"; do printf '    %s\n' "${NAMES[$i]}"; done
