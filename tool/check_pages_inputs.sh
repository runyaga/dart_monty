#!/usr/bin/env bash
# =============================================================================
# Every file the Pages deploy copies must exist BEFORE the deploy runs
# =============================================================================
# .github/workflows/pages.yaml assembles the site by copying from five places.
# If any of them is missing, the deploy step fails — and GitHub Pages KEEPS
# SERVING THE LAST GOOD BUILD, so the breakage presents as "the site is stale"
# rather than "the site is broken". The live site was last built 2026-06-02 and
# that is exactly how a 315-commit-stale dart_monty_core ref went unnoticed.
#
# This is deliberately an INPUTS check, not a build. dart_monty has no local
# equivalent of dart_monty_core's tool/check_pages.sh (which builds and serves
# the site), and a full mkdocs + dart2js + asset build is not something the
# gate should carry. What it can do cheaply is assert that every path the
# workflow names is really there, so a rename or a moved fixture fails on the
# branch rather than silently freezing the published site.
#
# NOT checked here, and stated so nobody reads more into a green tick:
#   - that the site BUILDS (mkdocs, dart2js)
#   - that the assembled pages render or that links resolve
#   - the dart_monty_core assets, which are copied from a checkout made inside
#     the workflow and do not exist locally
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

RC=0
# Two distinct severities, because conflating them misleads. A missing COPY
# SOURCE fails the deploy (and the published site hides that by serving the
# last good build). A missing PLACEHOLDER does not fail anything — the step
# silently substitutes nothing, forever, which is worse in its own way because
# nothing ever reports it.
miss() {
  echo "FAIL: $1"
  echo "      pages.yaml copies or compiles this; a missing path FAILS THE DEPLOY,"
  echo "      which the published site hides by serving the last good build."
  RC=1
}
noop() {
  echo "FAIL: $1"
  echo "      This does not fail the deploy — the step succeeds having done"
  echo "      NOTHING. Either restore the placeholder or delete the step."
  RC=1
}

# cp -r example/web/web/* site/
[ -d example/web/web ] && [ -n "$(ls -A example/web/web 2>/dev/null)" ] \
  || miss "example/web/web/ is missing or empty"

# cp test/fixtures/python_ladder/tier_*.json site/fixtures/
ladder=$(ls test/fixtures/python_ladder/tier_*.json 2>/dev/null | wc -l | tr -d ' ')
[ "$ladder" -gt 0 ] || miss "test/fixtures/python_ladder/tier_*.json matched nothing"

# cp -r docs/assets/* site/assets/
[ -d docs/assets ] && [ -n "$(ls -A docs/assets 2>/dev/null)" ] \
  || miss "docs/assets/ is missing or empty"

# If a __BUILD_DATE__ stamp step is ever reintroduced, the placeholder must
# exist in a SOURCE file or the sed is a silent no-op — which is exactly what
# was removed from pages.yaml. Hold the two together from the start.
# Match a real substitution, not a mention. The removal comment in pages.yaml
# names the placeholder, and a guard that trips on its own documentation is a
# guard nobody keeps.
if grep -E '^[^#]*sed[^#]*__BUILD_DATE__' .github/workflows/pages.yaml >/dev/null 2>&1; then
  grep -rq '__BUILD_DATE__' docs/ 2>/dev/null \
    || noop "pages.yaml seds for __BUILD_DATE__ but no file under docs/ contains it"
fi

# every bin/*.dart pages.yaml compiles must exist
for f in $(grep -oE 'bin/[a-z_]+\.dart' .github/workflows/pages.yaml | sort -u); do
  [ -f "example/web/$f" ] || miss "pages.yaml compiles example/web/$f, which does not exist"
done

[ "$RC" = "0" ] && echo "PASS — every path pages.yaml copies or compiles exists"
exit $RC
