#!/usr/bin/env bash
# =============================================================================
# Python Compatibility Ladder — WASM gate
# =============================================================================
# Builds the example/web ladder showcase, runs all tier_*.json fixtures in
# headless Chrome, and compares results against known_failures.txt.
# Reports per-tier pass/fail; exits 1 on any new failure.
#
# Usage: bash tool/test_python_ladder.sh [--verbose|-v]
#   --verbose / -v   Print every LADDER_RESULT line from the browser.
#                    Default: one summary line.
#
# Note: the previous version of this script also ran an FFI-side ladder
# via a `python_ladder_runner.dart` that no longer exists in the tree.
# Native conformance is covered by the oracle suite in dart_monty_core.
# =============================================================================
set -euo pipefail

VERBOSE=false
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel)"
EXAMPLE="$ROOT/example/web"
WEB_DIR="$EXAMPLE/web"
FIXTURES_SRC="$ROOT/test/fixtures/python_ladder"
KNOWN_FAILURES="$FIXTURES_SRC/known_failures.txt"

# Load known failures (strip comments + blanks).
KNOWN_FAILURE_LIST=""
if [ -f "$KNOWN_FAILURES" ]; then
  KNOWN_FAILURE_LIST=$(grep -v '^\s*#' "$KNOWN_FAILURES" \
    | grep -v '^\s*$' \
    | sed 's/\s*#.*//' \
    || true)
fi

is_known_failure() {
  echo "$KNOWN_FAILURE_LIST" | grep -qxF "$1" 2>/dev/null
}

NEW_FAILURES=()
KNOWN_HITS=()
KNOWN_NOW_PASSING=()

echo "=== Python Compatibility Ladder (WASM gate) ==="
echo ""

# ── Step 1: Build the ladder showcase ──────────────────────────────────
if $VERBOSE; then
  echo "--- Building example/web ladder showcase ---"
fi
cd "$EXAMPLE"
dart pub get >/dev/null

# Locate dart_monty_core's committed assets — same logic as
# example/web/run.sh.
if [ -n "${DART_MONTY_CORE_DIR:-}" ] && [ -d "$DART_MONTY_CORE_DIR/lib/assets" ]; then
  CORE_ASSETS="$DART_MONTY_CORE_DIR/lib/assets"
else
  CORE_ASSETS_GLOB="$(dart pub cache dir)/hosted/pub.dev/dart_monty_core-"*/lib/assets
  CORE_ASSETS=""
  for d in $CORE_ASSETS_GLOB; do
    if [ -d "$d" ]; then CORE_ASSETS="$d"; break; fi
  done
  if [ -z "$CORE_ASSETS" ]; then
    # git: deps land under ~/.pub-cache/git/<pkg>-<sha>/lib/assets.
    CORE_ASSETS=$(find "$HOME/.pub-cache/git" -maxdepth 3 -type d \
      -name 'dart_monty_core-*' 2>/dev/null \
      | head -1)
    [ -n "$CORE_ASSETS" ] && CORE_ASSETS="$CORE_ASSETS/lib/assets"
  fi
fi

if [ ! -d "$CORE_ASSETS" ]; then
  echo "FATAL: dart_monty_core assets not found." >&2
  echo "  Set DART_MONTY_CORE_DIR to a local checkout, or run" >&2
  echo "  'dart pub get' in $EXAMPLE first." >&2
  exit 1
fi

cp "$CORE_ASSETS/dart_monty_core_bridge.js" "$WEB_DIR/"
cp "$CORE_ASSETS/dart_monty_core_worker.js" "$WEB_DIR/"
cp "$CORE_ASSETS/dart_monty_core_native.wasm" "$WEB_DIR/"

mkdir -p "$WEB_DIR/fixtures"
cp "$FIXTURES_SRC"/tier_*.json "$WEB_DIR/fixtures/"

dart compile js bin/ladder_showcase.dart \
  -o "$WEB_DIR/ladder_showcase.dart.js" \
  >/dev/null 2>&1

# ── Step 2: Serve with COOP/COEP headers ───────────────────────────────
SERVE_PORT=8098
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -f \
    "$WEB_DIR/dart_monty_core_bridge.js" \
    "$WEB_DIR/dart_monty_core_worker.js" \
    "$WEB_DIR/dart_monty_core_native.wasm" \
    "$WEB_DIR/ladder_showcase.dart.js" \
    "$WEB_DIR/ladder_showcase.dart.js.deps" \
    "$WEB_DIR/ladder_showcase.dart.js.map"
  rm -rf "$WEB_DIR/fixtures"
}
trap cleanup EXIT

python3 -c "
import http.server, functools
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def guess_type(self, path):
        if path.endswith('.mjs'): return 'application/javascript'
        if path.endswith('.wasm'): return 'application/wasm'
        return super().guess_type(path)
    def log_message(self, *a): pass
handler = functools.partial(H, directory='$WEB_DIR')
http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler).serve_forever()
" &
SERVE_PID=$!
sleep 1

# ── Step 3: Headless Chrome ────────────────────────────────────────────
CHROME=""
if command -v google-chrome-stable &>/dev/null; then
  CHROME="google-chrome-stable"
elif command -v google-chrome &>/dev/null; then
  CHROME="google-chrome"
elif [ -f "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
elif command -v chromium &>/dev/null; then
  CHROME="chromium"
fi

if [ -z "$CHROME" ]; then
  echo "  WASM  SKIPPED (Chrome not found)"
  echo "=== Ladder: SKIPPED (no Chrome) ==="
  exit 0
fi

CONSOLE_LOG=$(mktemp)
timeout 90 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/ladder.html" \
  2>"$CONSOLE_LOG" || true

WEB_RESULTS=$(grep -o 'LADDER_RESULT:{[^}]*}' "$CONSOLE_LOG" 2>/dev/null || true)
rm -f "$CONSOLE_LOG"

if [ -z "$WEB_RESULTS" ]; then
  echo "  WASM  INCONCLUSIVE (no LADDER_RESULT lines from Chrome)"
  echo "=== Ladder: INCONCLUSIVE ==="
  exit 1
fi

# ── Step 4: Parse + compare against known_failures.txt ─────────────────
TOTAL=0
PASSED=0
while IFS= read -r line; do
  TOTAL=$((TOTAL + 1))
  TIER=$(echo "$line" | sed -E 's/.*"tier"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  NAME=$(echo "$line" | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
  OK=$(echo "$line" | sed -E 's/.*"ok"[[:space:]]*:[[:space:]]*(true|false).*/\1/')
  KEY="$TIER:$NAME"

  if [ "$OK" = "true" ]; then
    PASSED=$((PASSED + 1))
    if is_known_failure "$KEY"; then
      KNOWN_NOW_PASSING+=("$KEY")
    fi
  else
    if is_known_failure "$KEY"; then
      KNOWN_HITS+=("$KEY")
    else
      NEW_FAILURES+=("$KEY")
    fi
  fi

  if $VERBOSE; then echo "  $line"; fi
done <<< "$WEB_RESULTS"

echo "  WASM  $PASSED/$TOTAL passed"

if [ "${#NEW_FAILURES[@]}" -gt 0 ]; then
  echo ""
  echo "  NEW failures (not in known_failures.txt):"
  for f in "${NEW_FAILURES[@]}"; do echo "    $f"; done
  echo ""
  echo "=== Ladder: FAILED ==="
  exit 1
fi

if [ "${#KNOWN_NOW_PASSING[@]}" -gt 0 ]; then
  echo ""
  echo "  KNOWN failures now passing (remove from known_failures.txt):"
  for k in "${KNOWN_NOW_PASSING[@]}"; do echo "    $k"; done
fi

if $VERBOSE && [ "${#KNOWN_HITS[@]}" -gt 0 ]; then
  echo ""
  echo "  KNOWN failures still failing (expected):"
  for k in "${KNOWN_HITS[@]}"; do echo "    $k"; done
fi

echo "=== Ladder: PASSED ==="
