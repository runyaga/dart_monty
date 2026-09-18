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
N=0
# DISCOVERED, NOT ENUMERATED. This read
#     for page in example/web/web/index.html docs/index.md
# -- exactly two files by name -- and so could not see that SEVEN of the eight
# published demo pages stated no version at all. Measured 2026-09-16: a reader
# landing on vfs.html saw "(0.18)" feature labels and nothing else, and had no
# way to tell whether the demo was current. That is precisely the failure this
# check exists to prevent, and the check was structurally blind to it.
#
# Every tracked .html under example/web/web/ is deployed, so every one of them
# must carry the badge. Adding a ninth page now fails here until it does, rather
# than shipping unversioned.
PAGES="$(git ls-files 'example/web/web/*.html') docs/index.md"
[ -n "$(git ls-files 'example/web/web/*.html')" ] || {
  echo "FAIL: no published pages matched example/web/web/*.html."
  echo "  A glob that stopped matching would make this check verify nothing."
  exit 1; }
for page in $PAGES; do
  N=$((N+1))
  [ -f "$page" ] || { echo "FAIL: $page is missing"; RC=1; continue; }
  grep -q "$VER" "$page" || {
    echo "FAIL: $page does not state dart_monty version $VER"
    echo "      pubspec.yaml says $VER; the page says:"
    grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' "$page" | head -3 | sed 's/^/        /'
    RC=1; }
  # ANCHORED TO `dart_monty_core`, not a bare ref match. Measured 2026-09-17:
  # when the core pin moved from the `integration/0.23` branch to the `v0.23.0`
  # tag, REF became the same string as VER -- so a bare `grep -q "$REF"` matched
  # the dart_monty VERSION already on the page and this check passed while every
  # badge still read "dart_monty_core integration/0.23". A check that a release
  # bump can satisfy by accident verifies nothing at exactly the moment it is
  # needed most.
  # Backticks stripped first, and a FIXED-string match: the HTML badges write
  # `dart_monty_core v0.23.0` bare, docs/index.md writes it as two inline-code
  # spans, and a ref like `v0.23.0` is full of regex metacharacters.
  # NO PIPE HERE, DELIBERATELY. `tr ... | grep -q` makes grep exit on the first
  # match, which SIGPIPEs tr, which under `set -o pipefail` reports the pipeline
  # as failed -- so a page that DOES carry the badge intermittently reported as
  # missing it, and which page varied run to run. Substitution + a case glob has
  # no second process to kill.
  page_text="$(tr -d '`' < "$page")"
  case "$page_text" in
    *"dart_monty_core $REF"*) : ;;
    *) {
    echo "FAIL: $page does not state the dart_monty_core ref $REF"
    echo "      expected the text: dart_monty_core $REF"
    echo "      page says:"
    grep -oE 'dart_monty_core [^<"&]*' "$page" | head -2 | sed 's/^/        /'
    RC=1; };;
  esac
done

[ "$RC" = "0" ] && echo "PASS — $N published page(s) state v$VER against $REF"
exit $RC
