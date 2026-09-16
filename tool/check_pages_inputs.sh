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

# pip install -r <file>
# pages.yaml installs a REQUIREMENTS FILE before it builds; if that file is
# gone the deploy fails and the site silently serves the last good build, the
# same failure mode as a missing copy source. This matters more since the
# install moved from requirements-docs.txt (bounds) to requirements-docs.lock:
# issue #451 §5 calls out the deletion-order trap explicitly — the lock must
# not be removed while pages.yaml still installs it. The filename is READ OUT
# OF pages.yaml rather than hardcoded, so switching files can never leave this
# check asserting the existence of one nothing installs.
reqs=$(grep -oE 'pip install -r [A-Za-z0-9._/-]+' .github/workflows/pages.yaml \
       | awk '{print $NF}' | sort -u)
if [ -z "$reqs" ]; then
  noop "pages.yaml no longer runs 'pip install -r <file>'; this check now verifies nothing"
else
  for r in $reqs; do
    [ -s "$r" ] || miss "pages.yaml installs $r, which is missing or empty"
  done
fi

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

# EVERY entrypoint the SITE loads must be compiled by pages.yaml.
#
# This is the check that would have caught a live 404. pages.yaml compiled six
# of the seven entrypoints; async_matrix.html and index.html both reference
# async_matrix_demo.dart.js; every .dart.js is gitignored, so nothing filled the
# gap on a fresh checkout. Measured against the deployed site:
#   main.dart.js 200, repl_demo.dart.js 200, visualizer.dart.js 200,
#   async_matrix_demo.dart.js 404 — while async_matrix.html itself returned 200.
# A page that loads and a script that does not is exactly the failure Pages
# hides, because the HTML still deploys.
for js in $(grep -rhoE 'src="[a-z_]+\.dart\.js"' example/web/web/*.html 2>/dev/null \
            | sed 's/src="//; s/"//' | sort -u); do
  entry="bin/${js%.js}"
  grep -q "$entry" .github/workflows/pages.yaml \
    || miss "the site loads $js but pages.yaml never compiles $entry"
done

# EVERY local .html link on the demo pages must have a source.
#
# The demo shell links both to sibling pages (repl.html) and INTO the mkdocs
# output (user/repl.html <- docs/user/repl.md). Remove a doc from docs/, or drop
# it from the mkdocs nav, and the link 404s on a site that still deploys green —
# the same shape as the async_matrix_demo.dart.js 404 this file already caught.
#
# Deliberately static: it resolves a link to a SOURCE rather than fetching the
# deployed page. dart_monty_core's tool/check_pages.sh does build and serve and
# is strictly better; a full mkdocs + dart2js build was judged too heavy for
# this gate. So this closes the cheap half of that gap and no more — it cannot
# see a broken mkdocs nav that still renders the file, or a link that resolves
# to a page which itself fails to build.
for href in $(grep -ohE 'href="[^"]+\.html"' example/web/web/*.html 2>/dev/null \
              | sed 's/href="//; s/"//; s|^\./||' | sort -u); do
  [ -f "example/web/web/$href" ] && continue
  [ -f "docs/${href%.html}.md" ] && continue
  miss "a demo page links to $href, which is neither a sibling page nor docs/${href%.html}.md"
done

# EVERY relative .md link inside docs/ must resolve.
#
# The guard above reads the DEMO pages' href targets. It does not read links
# BETWEEN docs, and that is where a live 404 was hiding:
# docs/deep-dives/bridge-concurrency.md linked to lifecycles.md, a document that
# was never written, and https://runyaga.github.io/dart_monty/deep-dives/lifecycles.html
# returned 404 on the deployed site.
#
# `mkdocs build --strict` would catch this, and does — but it is unusable here:
# `use_directory_urls: false` makes `.html` links correct while --strict
# resolves them against `.md` source names, so it reports 26 false failures
# alongside the one real link. A gate that is wrong 26 times out of 27 gets
# switched off. This checks only the unambiguous case: a relative .md target
# that does not exist on disk.
python3 - <<'PYCHECK' || RC=1
import re, os, glob, sys
bad = []
for f in glob.glob('docs/**/*.md', recursive=True):
    for m in re.finditer(r'\]\(([^)#:]+\.md)(?:#[^)]*)?\)', open(f).read()):
        t = os.path.normpath(os.path.join(os.path.dirname(f), m.group(1)))
        if not os.path.exists(t):
            bad.append((f, m.group(1)))
for f, link in bad:
    print(f"FAIL: {f} links to {link}, which does not exist")
if bad:
    print("      A dead docs link 404s on the published site; the deploy stays green.")
sys.exit(1 if bad else 0)
PYCHECK

# THE llms.txt SURFACE IS PUBLISHED AND UNGUARDED.
#
# The `llmstxt` mkdocs plugin emits 29 live endpoints — llms.txt, llms-full.txt,
# and a raw `.md` for every page. All 29 return HTTP 200 today; measured
# 2026-09-16 while researching the Zensical migration (issue #451). Nothing in
# this repo asserts they exist, so removing the plugin, or a docs tool that does
# not implement it, drops the entire surface SILENTLY: the build still exits 0,
# the HTML is unchanged, and only fetching one of the 29 reveals it.
#
# That is precisely how Zensical would break this today — it builds this
# mkdocs.yml clean, emits the identical HTML set, and prints NOTHING about the
# 29 it does not produce.
#
# The plugin must stay declared in BOTH places or the surface is gone.
if ! grep -qE '^\s*-\s*llmstxt:' mkdocs.yml 2>/dev/null; then
  noop "mkdocs.yml no longer declares the llmstxt plugin — llms.txt, llms-full.txt and 27 raw .md endpoints stop being published"
fi
if ! grep -qE '^\s*mkdocs-llmstxt' requirements-docs.txt 2>/dev/null; then
  miss "requirements-docs.txt does not pin mkdocs-llmstxt; the plugin mkdocs.yml declares will not install"
fi

# every bin/*.dart pages.yaml compiles must exist
for f in $(grep -oE 'bin/[a-z_]+\.dart' .github/workflows/pages.yaml | sort -u); do
  [ -f "example/web/$f" ] || miss "pages.yaml compiles example/web/$f, which does not exist"
done

[ "$RC" = "0" ] && echo "PASS — every path pages.yaml copies or compiles exists"
exit $RC
