#!/usr/bin/env bash
# =============================================================================
# Every published page must state the version it was built from, correctly
# =============================================================================
# The deployed site is the one artefact a user meets without a pubspec in front
# of them, and "the demo is broken" and "the demo is old" are indistinguishable
# without a version on the page. This repo has just paid for that twice: a site
# last built 2026-06-02 that read as current, and a dart_monty_core ref 315
# commits stale that nobody could see from the page.
#
# WHY HAND-WRITTEN AND CHECKED, RATHER THAN INJECTED AT BUILD TIME.
# pages.yaml used to carry `sed -i "s/__BUILD_DATE__/$stamp/g" site/index.html`
# for a placeholder that existed in NO source file. It substituted nothing,
# exited 0, and reported success on every deploy. An injected value fails
# silently when the placeholder drifts; a hand-written value with a check fails
# loudly. Same reasoning as dart_monty_core/tool/check_page_versions.sh.
#
# Sources of truth:
#   dart_monty version  -> pubspec.yaml `version:`
#   dart_monty_core ref -> pubspec.yaml dependency_overrides `ref:`
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

VER="$(grep -m1 -E '^version:' pubspec.yaml | awk '{print $2}')"
REF="$(awk '/^dependency_overrides:/,0' pubspec.yaml \
       | sed -nE 's/^[[:space:]]*ref:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -1)"

[ -n "$VER" ] || { echo "FAIL: could not read version: from pubspec.yaml"; exit 1; }
[ -n "$REF" ] || { echo "FAIL: could not read the dart_monty_core ref from pubspec.yaml"; exit 1; }

RC=0
for page in example/web/web/index.html docs/index.md; do
  [ -f "$page" ] || { echo "FAIL: $page is missing"; RC=1; continue; }
  grep -q "$VER" "$page" || {
    echo "FAIL: $page does not state dart_monty version $VER"
    echo "      pubspec.yaml says $VER; the page says:"
    grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' "$page" | head -3 | sed 's/^/        /'
    RC=1; }
  grep -q "$REF" "$page" || {
    echo "FAIL: $page does not state the dart_monty_core ref $REF"
    RC=1; }
done

[ "$RC" = "0" ] && echo "PASS — both published pages state v$VER against $REF"
exit $RC
