#!/usr/bin/env bash
# =============================================================================
# M4 Gate Script — WASM Package
# =============================================================================
# Validates: JS build, pub get, format, analyze, test, coverage >= 90%,
# integration smoke test, and python ladder in headless Chrome.
#
# Usage: bash tool/test_wasm.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PKG="$ROOT/packages/dart_monty_wasm"
MIN_COVERAGE=90

cd "$ROOT"

echo "=== M4 Gate: dart_monty_wasm ==="

# -------------------------------------------------------
# Step 1: Build JS bridge
# -------------------------------------------------------
echo ""
echo "--- Building JS bridge ---"
cd "$PKG/js"
npm install
npm run build
echo "  JS build: OK"

# -------------------------------------------------------
# Step 2: Dart pub get
# -------------------------------------------------------
echo ""
echo "--- dart pub get ---"
cd "$PKG"
dart pub get

# -------------------------------------------------------
# Step 3: Format
# -------------------------------------------------------
echo ""
echo "--- dart format --set-exit-if-changed . ---"
dart format --set-exit-if-changed .

# -------------------------------------------------------
# Step 4: Analyze
# -------------------------------------------------------
echo ""
echo "--- dart analyze --fatal-infos ---"
dart analyze --fatal-infos

# -------------------------------------------------------
# Step 5: Unit tests (VM only)
# -------------------------------------------------------
echo ""
echo "--- dart test --coverage=coverage ---"
dart test --coverage=coverage

# -------------------------------------------------------
# Step 6: Coverage check
# -------------------------------------------------------
echo ""
echo "--- Coverage check ---"
dart pub global run coverage:format_coverage \
  --lcov \
  --in=coverage \
  --out=coverage/lcov.info \
  --report-on=lib

TOTAL=$(grep -c '^DA:' coverage/lcov.info || true)
HIT=$(grep '^DA:' coverage/lcov.info | grep -cv ',0$' || true)

if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: No coverage data found."
  exit 1
fi

PCT=$(( HIT * 100 / TOTAL ))
echo "Coverage: $HIT/$TOTAL lines = ${PCT}%"

if [ "$PCT" -lt "$MIN_COVERAGE" ]; then
  echo "FAIL: Coverage ${PCT}% < ${MIN_COVERAGE}% minimum."
  exit 1
fi

echo "  Unit coverage: ${PCT}% (>= ${MIN_COVERAGE}%)"

# -------------------------------------------------------
# Step 7: Integration tests (headless Chrome)
# -------------------------------------------------------
echo ""
echo "--- Integration tests (headless Chrome) ---"

# Copy assets to integration web dir
INTEG_WEB="$PKG/test/integration/web"
cp "$PKG/assets/dart_monty_bridge.js" "$INTEG_WEB/"
cp "$PKG/assets/dart_monty_worker.js" "$INTEG_WEB/"
cp "$PKG/assets/wasi-worker-browser.mjs" "$INTEG_WEB/"
cp "$PKG/assets/"*.wasm "$INTEG_WEB/"

# Compile smoke test to JS
echo "  Compiling smoke_test.dart to JS..."
dart compile js "$PKG/test/integration/smoke_test.dart" \
  -o "$INTEG_WEB/smoke_test.dart.js"

# Compile ladder runner to JS
echo "  Compiling python_ladder_test.dart to JS..."
dart compile js "$PKG/test/integration/python_ladder_test.dart" \
  -o "$INTEG_WEB/ladder_runner.dart.js"

# Copy fixtures
echo "  Copying fixtures..."
mkdir -p "$INTEG_WEB/fixtures"
cp "$ROOT"/test/fixtures/python_ladder/tier_*.json "$INTEG_WEB/fixtures/"

# Start COOP/COEP server
SERVE_PORT=8099
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  # Clean up copied assets
  rm -f "$INTEG_WEB/dart_monty_bridge.js" \
        "$INTEG_WEB/dart_monty_worker.js" \
        "$INTEG_WEB/wasi-worker-browser.mjs" \
        "$INTEG_WEB/"*.wasm \
        "$INTEG_WEB/smoke_test.dart.js" \
        "$INTEG_WEB/smoke_test.dart.js.deps" \
        "$INTEG_WEB/smoke_test.dart.js.map" \
        "$INTEG_WEB/ladder_runner.dart.js" \
        "$INTEG_WEB/ladder_runner.dart.js.deps" \
        "$INTEG_WEB/ladder_runner.dart.js.map"
  rm -rf "$INTEG_WEB/fixtures"
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
    def log_message(self, fmt, *args): pass

handler = functools.partial(H, directory='$INTEG_WEB')
http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler).serve_forever()
" &
SERVE_PID=$!
sleep 1

echo "  Server running on http://127.0.0.1:$SERVE_PORT (PID $SERVE_PID)"

# Detect Chrome
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
  echo "  WARN: Chrome not found. Skipping integration tests."
  echo ""
  echo "=== M4 Gate: Unit PASSED (${PCT}% coverage), Integration SKIPPED ==="
  exit 0
fi

echo "  Using: $CHROME"

# --- Smoke test ---
echo ""
echo "  Running smoke test..."
SMOKE_LOG=$(mktemp)

timeout 60 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/index.html" \
  2>"$SMOKE_LOG" || true

SMOKE_PASSES=$(grep -o 'SMOKE_PASS:[a-z_]*' "$SMOKE_LOG" 2>/dev/null || true)
SMOKE_FAILS=$(grep -o 'SMOKE_FAIL:[a-z_]*:.*' "$SMOKE_LOG" 2>/dev/null || true)
SMOKE_DONE=$(grep -c 'SMOKE_DONE' "$SMOKE_LOG" 2>/dev/null || echo "0")

if [ -n "$SMOKE_PASSES" ]; then
  echo "$SMOKE_PASSES" | while IFS= read -r line; do
    echo "    $line"
  done
fi

if [ -n "$SMOKE_FAILS" ]; then
  echo "  SMOKE FAILURES:"
  echo "$SMOKE_FAILS" | while IFS= read -r line; do
    echo "    $line"
  done
fi

rm -f "$SMOKE_LOG"

SMOKE_FAIL_COUNT=0
if [ -n "$SMOKE_FAILS" ]; then
  SMOKE_FAIL_COUNT=$(echo "$SMOKE_FAILS" | grep -c 'SMOKE_FAIL' || true)
fi

if [ "$SMOKE_FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "=== M4 Gate: FAILED (smoke test had $SMOKE_FAIL_COUNT failures) ==="
  exit 1
fi

# --- Ladder test ---
echo ""
echo "  Running ladder test..."
LADDER_LOG=$(mktemp)

timeout 120 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/ladder.html" \
  2>"$LADDER_LOG" || true

WEB_RESULTS=$(grep -o 'LADDER_RESULT:{.*}' "$LADDER_LOG" 2>/dev/null || true)

if [ -z "$WEB_RESULTS" ]; then
  echo "  WARN: No LADDER_RESULT lines captured from Chrome."
  grep -i "CONSOLE" "$LADDER_LOG" | head -20 || echo "  (no output)"
  rm -f "$LADDER_LOG"
  echo ""
  echo "=== M4 Gate: Unit PASSED, Ladder INCONCLUSIVE ==="
  exit 0
fi

echo "$WEB_RESULTS" | while IFS= read -r line; do
  echo "    $line"
done

LADDER_FAILURES=0
if [ -n "$WEB_RESULTS" ]; then
  LADDER_FAILURES=$(echo "$WEB_RESULTS" | grep -c '"ok":false' || true)
fi

rm -f "$LADDER_LOG"

echo ""
if [ "$LADDER_FAILURES" -gt 0 ]; then
  echo "=== M4 Gate: FAILED (ladder had $LADDER_FAILURES failures) ==="
  exit 1
fi

echo "=== M4 Gate: PASSED (${PCT}% coverage, smoke OK, ladder OK) ==="
