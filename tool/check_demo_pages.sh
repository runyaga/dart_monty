#!/usr/bin/env bash
# =============================================================================
# Every published demo must actually RUN — in a real browser, on every commit
# =============================================================================
# Measured on integration/0.23 before this script existed:
#
#   example/*.dart            4   EXECUTED   test/integration/example_smoke_test.dart
#   example/web/bin/*.dart    7   COMPILED ONLY — ci.yaml ran `dart compile js`
#                                 per file and never ran the result
#   example/web/web/*.html    8   NOT EXERCISED AT ALL — nothing loaded them
#
# A demo that compiles can still throw on load, 404 its own `.dart.js`, or fail
# to boot WASM. This repo has already paid for exactly that:
# async_matrix_demo.dart.js returned 404 on the live site while
# async_matrix.html returned 200, and the site sat stale from 2026-06-02 with
# every check green — because GitHub Pages hides a failed build by continuing
# to serve the last good one.
#
# So this assembles the site the way .github/workflows/pages.yaml does, then
# hands it to test/integration/demo_page_boot_test.dart, which serves it and
# drives headless Chrome at every page.
#
# WHAT IT DOES NOT DO, stated so nobody reads more into a green tick:
#   - it does not build the mkdocs half of the site (docs links are covered
#     statically by tool/check_pages_inputs.sh)
#   - it drives every example in a page's dropdown, but not the page's other
#     controls (mount, reset, tab switches, the visualizer's start button)
#
# Usage: bash tool/check_demo_pages.sh
# Exit:  0 pass · 1 fail · 77 SKIPPED (no browser; a skip is NOT a pass)
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

SITE=build/demo-site
WEB=example/web

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------- concurrency
# This mutates a SHARED path (build/demo-site) and binds a browser, so two runs
# in one clone corrupt each other. dart_monty_core's tool/check_pages.sh
# documents what that costs: the second run's `rm -rf` deleted the first run's
# site mid-flight and the first run reported a wiring defect that did not
# exist. A red that names the wrong cause is worse than a wait.
LOCKDIR="${TMPDIR:-/tmp}/dm-check-demo-pages-$(pwd | shasum -a 256 | cut -c1-12).lock"
LOCK_HELD=""
cleanup() { [ -n "$LOCK_HELD" ] && rm -rf "$LOCKDIR"; return 0; }
trap cleanup EXIT
waited=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
  other=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "$other" ] && ! kill -0 "$other" 2>/dev/null; then
    echo "  note: clearing stale lock left by dead pid $other"; rm -rf "$LOCKDIR"; continue
  fi
  sleep 5; waited=$((waited + 5))
  [ "$waited" -ge 600 ] && fail "waited 600s for $LOCKDIR — is another run wedged?"
done
LOCK_HELD=1
echo $$ > "$LOCKDIR/pid"

# ---------------------------------------------------------------- discovery
# DISCOVERED, NOT ENUMERATED — the rule tool/check_page_versions.sh already
# follows. Its predecessor named two files and was therefore blind to seven
# unversioned pages. A glob that stops matching must FAIL, not silently verify
# nothing: that is how a rename turns a gate into a no-op that reports success.
PAGES=$(git ls-files 'example/web/web/*.html')
ENTRYPOINTS=$(git ls-files 'example/web/bin/*.dart')
[ -n "$PAGES" ] || fail "git ls-files 'example/web/web/*.html' matched nothing"
[ -n "$ENTRYPOINTS" ] || fail "git ls-files 'example/web/bin/*.dart' matched nothing"
NPAGES=$(echo "$PAGES" | wc -l | tr -d ' ')
NENTRY=$(echo "$ENTRYPOINTS" | wc -l | tr -d ' ')

# THE EXAMPLES INSIDE THE PAGES, TOO. A page that boots is not a page that
# works: agent.html and vfs.html each carry a dropdown of self-contained
# examples, and vfs.html's open() example was failing on the LIVE SITE while
# the page around it came up perfectly clean. Counted here so the floor below
# covers EXAMPLES RUN rather than pages visited — 30 today, derived rather
# than typed, so a 31st is covered by the commit that adds it.
#
# The empty placeholder option is not an example. This static count is
# cross-checked in the suite against what the live DOM offers, so a selector
# that stops matching in either place fails instead of shrinking coverage.
# A PAGE THAT CANNOT BE READ MUST NOT COUNT AS ZERO EXAMPLES, and MARKUP
# INSIDE A <script> OR A COMMENT IS NOT AN EXAMPLE. Both were measured while
# falsifying this script. An unreadable page dropped the floor from 46 to 38
# silently. And an option element written inside a JS COMMENT -- the comment
# documenting this very check -- was counted as a real example on two pages,
# pushing the floor to 32 for a page set that offers 30, so the gate demanded
# tests for demos that do not exist. A gate that quietly lowers its own bar is
# worse than no gate; one that invents subjects it cannot run is just as bad.
#
# Kept in step with exampleKeysInHtml() in
# test/integration/demo_harness.dart, which strips the same two things. The
# suite asserts the static set equals what the live DOM offers, so any
# disagreement between the two fails loudly rather than shrinking coverage.
#
# `python3`, not grep+sed: both strips need a DOTALL match across lines, and a
# line-oriented tool cannot do that without becoming unreadable.
NEXAMPLES=$(python3 - $PAGES <<'PYCOUNT'
import re, sys

total = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        markup = handle.read()
    markup = re.sub(r"<script\b[^>]*>.*?</script>", "", markup, flags=re.S | re.I)
    markup = re.sub(r"<!--.*?-->", "", markup, flags=re.S)
    keys = []
    for key in re.findall(r"""<option[^>]*\svalue=["']([^"']*)["']""", markup):
        if key and key not in keys:
            keys.append(key)
    total += len(keys)
print(total)
PYCOUNT
) || fail "could not count the examples the published pages declare"
[ -n "$NEXAMPLES" ] || fail "the example count came back empty"
echo "discovered: $NPAGES published page(s), $NENTRY web entrypoint(s), $NEXAMPLES selectable example(s)"

# ---------------------------------------------------------------- browser
# A MISSING BROWSER IS A VISIBLE SKIP, NEVER A PASS. tool/gate.sh treats exit
# 77 as "did not run, checked nothing" and prints it in the summary — the same
# contract the DCM ratchets use. CI has Chrome, so CI sets DEMO_PAGES_STRICT=1
# and a missing browser there is a broken runner, not a skip.
CHROME="${CHROME_EXECUTABLE:-}"
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
  CHROME=""
  for c in google-chrome-stable google-chrome chromium chromium-browser \
           "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if command -v "$c" >/dev/null 2>&1; then CHROME="$(command -v "$c")"; break; fi
    if [ -x "$c" ]; then CHROME="$c"; break; fi
  done
fi
if [ -z "$CHROME" ]; then
  if [ "${DEMO_PAGES_STRICT:-0}" = "1" ]; then
    fail "no Chrome/Chromium found and DEMO_PAGES_STRICT=1 — this gate cannot run"
  fi
  echo "SKIP: no Chrome/Chromium found, so $NPAGES demo page(s) were NOT loaded."
  echo "  Install Chrome or set CHROME_EXECUTABLE. This is a skip, not a pass."
  exit 77
fi
export CHROME_EXECUTABLE="$CHROME"
echo "browser: $CHROME"

# ---------------------------------------------------------------- assemble
# Mirrors the copy/compile steps in .github/workflows/pages.yaml. Built from
# the DISCOVERED entrypoint list rather than pages.yaml's seven hand-written
# compile steps — that hand-written list is precisely how async_matrix_demo
# came to be the one entrypoint nothing compiled.
echo "--- pub get ($WEB) ---"
( cd "$WEB" && dart pub get ) >/dev/null || fail "dart pub get in $WEB"

# THE DEMOS MUST BE BUILT AGAINST THE CORE THIS BRANCH TARGETS.
#
# `dependency_overrides` do NOT propagate through a path dependency, so
# example/web declares its own; without it dart_monty_core resolves
# TRANSITIVELY FROM PUB.DEV while the package under test is on this line, and a
# green demo against the wrong core proves nothing. tool/check_core_ref.sh
# compares the four DECLARATIONS; this compares the declaration against what
# pub actually RESOLVED, which is the half no local check could see.
REF=$(awk '/^dependency_overrides:/,0' pubspec.yaml \
      | sed -nE 's/^[[:space:]]*ref:[[:space:]]*(.+)[[:space:]]*$/\1/p' | head -1)
[ -n "$REF" ] || fail "could not read the dart_monty_core ref from pubspec.yaml"
grep -q "ref: \"$REF\"" "$WEB/pubspec.lock" \
  || fail "$WEB resolved dart_monty_core from somewhere other than $REF:
$(sed -n '/dart_monty_core:/,/^  [a-z]/p' "$WEB/pubspec.lock" | sed 's/^/      /')"
echo "core ref: $REF (declared and resolved)"

rm -rf "$SITE"
mkdir -p "$SITE/fixtures"
cp -r "$WEB"/web/* "$SITE"/ || fail "copy $WEB/web -> $SITE"

echo "--- dart compile js ($NENTRY entrypoints) ---"
built=0
for entry in $ENTRYPOINTS; do
  base=$(basename "${entry%.dart}")
  ( cd "$WEB" && dart compile js "bin/$base.dart" \
      -o "../../$SITE/$base.dart.js" --no-source-maps ) >/dev/null \
    || fail "dart compile js $entry"
  built=$((built + 1))
done
# COUNT, don't just loop: the loop compiles whatever happens to be there, so
# losing an entrypoint would leave this step green having built one fewer.
[ "$built" -eq "$NENTRY" ] || fail "compiled $built of $NENTRY entrypoints"
echo "compiled $built entrypoint(s)"

# The committed WASM assets, from the RESOLVED dart_monty_core — not a
# hardcoded pub-cache path, and not `main`. pages.yaml copies these from a
# checkout of the ref named in pubspec.yaml; reading the resolution is the
# local equivalent and cannot drift from what $WEB actually compiled against.
CORE=$(python3 - "$WEB/.dart_tool/package_config.json" <<'PY'
import json, sys, urllib.parse
cfg = json.load(open(sys.argv[1]))
for pkg in cfg["packages"]:
    if pkg["name"] == "dart_monty_core":
        print(urllib.parse.urlparse(pkg["rootUri"]).path)
        break
PY
)
[ -n "$CORE" ] && [ -d "$CORE/lib/assets" ] \
  || fail "could not resolve dart_monty_core assets from $WEB/.dart_tool/package_config.json"
for asset in dart_monty_core_bridge.js dart_monty_core_worker.js dart_monty_core_native.wasm; do
  cp "$CORE/lib/assets/$asset" "$SITE/" || fail "missing $CORE/lib/assets/$asset"
done
cp test/fixtures/python_ladder/tier_*.json "$SITE/fixtures/" \
  || fail "test/fixtures/python_ladder/tier_*.json matched nothing"
echo "assembled $SITE ($(find "$SITE" -type f | wc -l | tr -d ' ') files)"

# ---------------------------------------------------------------- drive
# BEWARE PIPE-MASKED EXIT CODES. `dart test | tee` yields tee's status, which
# is 0 for a failing suite. Captured explicitly rather than relying on
# pipefail alone, because this gate's whole value is in the exit code.
LOG=$(mktemp)
echo "--- dart test (headless Chrome) ---"
set -o pipefail
dart test test/integration/demo_page_boot_test.dart \
  -p vm --run-skipped --tags=demo --reporter=expanded 2>&1 | tee "$LOG"
RC=$?
set +o pipefail

# A SUITE THAT REGISTERS ZERO TESTS PRINTS SUCCESS AND EXITS 0.
# The floor is DERIVED from the discovered sets rather than hardcoded, so
# adding a ninth page or a thirty-first example raises it in the same commit
# that adds it: one test per page, one per entrypoint, ONE PER EXAMPLE, plus
# the coverage assertion.
FLOOR=$((NPAGES + NENTRY + NEXAMPLES + 1))
bash tool/assert_test_count.sh "$LOG" "$FLOOR" demo || RC=1

[ "$RC" = "0" ] || fail "the published demos do not all boot (see above)"
echo "PASS — $NPAGES page(s) booted, $NENTRY entrypoint(s) executed and"
echo "       $NEXAMPLES selectable example(s) ran green in $CHROME"
