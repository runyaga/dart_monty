#!/usr/bin/env bash
# Build once; smoke the exact artifact. Chrome is required for a passing smoke.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
MODE=${1:-all}
SITE=build/demo-site
mkdir -p build
LOCK=build/.demo-pages-lock
if ! mkdir "$LOCK" 2>/dev/null; then
  echo 'FAIL: another demo Pages check owns build/.demo-pages-lock'
  exit 1
fi
trap 'rmdir "$LOCK"' EXIT
if [ "$MODE" != --smoke-only ]; then
  mkdir -p build
  dart pub get --offline
  (cd example/web && dart pub get --offline)
  python3 tool/build_page_metadata.py
  bash tool/check_page_versions.sh
  mkdocs build --site-dir "$SITE"
  cp -R example/web/web/. "$SITE/"
  for entry in example/web/bin/*.dart; do
    base=$(basename "${entry%.dart}")
    dart compile js --packages=example/web/.dart_tool/package_config.json \
      "$entry" -o "$SITE/$base.dart.js" --no-source-maps
  done
  CORE=$(python3 - <<'PY'
import json
from pathlib import Path
from urllib.parse import urljoin, urlparse
p = Path('example/web/.dart_tool/package_config.json').resolve()
pkg = next(x for x in json.loads(p.read_text())['packages'] if x['name'] == 'dart_monty_core')
print(urlparse(urljoin(p.as_uri(), pkg['rootUri'])).path)
PY
)
  cp "$CORE"/lib/assets/dart_monty_core_worker.{js,wasm} "$SITE/"
  mkdir -p "$SITE/fixtures" "$SITE/assets"
  cp test/fixtures/python_ladder/tier_*.json "$SITE/fixtures/"
  cp -R docs/assets/. "$SITE/assets/"
  python3 tool/check_site_tree.py "$SITE"
fi
[ "$MODE" != --build-only ] || exit 0
python3 tool/check_site_tree.py "$SITE"
CHROME=${CHROME_EXECUTABLE:-}
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
  CHROME=""
  for c in google-chrome-stable google-chrome chromium chromium-browser \
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
      "/Applications/Chromium.app/Contents/MacOS/Chromium"; do
    if command -v "$c" >/dev/null 2>&1; then CHROME=$(command -v "$c"); break; fi
    if [ -x "$c" ]; then CHROME="$c"; break; fi
  done
fi
if [ -z "$CHROME" ] || [ ! -x "$CHROME" ]; then
  echo 'UNVERIFIED: Chrome unavailable; browser smoke did not run.'
  [ "${DEMO_PAGES_STRICT:-0}" != 1 ] || exit 1
  exit 77
fi
export CHROME_EXECUTABLE="$CHROME"
"$CHROME" --version
dart --version
for headers in 0 1; do
  DEMO_COI_HEADERS=$headers dart test test/integration/demo_page_boot_test.dart \
    -p vm --run-skipped --tags=demo --reporter=expanded
done
