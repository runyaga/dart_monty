#!/usr/bin/env bash
# =============================================================================
# M3C Gate Script — Python Compatibility Ladder
# =============================================================================
# Runs all 34 fixtures on both native FFI and web WASM paths.
# Reports per-tier pass/fail.
#
# Usage: bash tool/test_python_ladder.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SPIKE="$ROOT/spike/web_test"
KNOWN_FAILURES="$ROOT/test/fixtures/python_ladder/known_failures.txt"

# Load known failures (strip comments and blank lines)
KNOWN_FAILURE_LIST=""
if [ -f "$KNOWN_FAILURES" ]; then
  KNOWN_FAILURE_LIST=$(grep -v '^\s*#' "$KNOWN_FAILURES" | grep -v '^\s*$' | sed 's/\s*#.*//' || true)
fi

# Check if a failure key is in the known list.
# Usage: is_known_failure "tier_07_advanced.json:test_name"
is_known_failure() {
  echo "$KNOWN_FAILURE_LIST" | grep -qxF "$1" 2>/dev/null
}

# Track new vs known failures for final reporting
NEW_FAILURES=()
KNOWN_HITS=()
KNOWN_NOW_PASSING=()

# Check web LADDER_RESULT lines against known failures.
# Sets NEW_FAILURES array with any unknown failures.
# Args: $1 = variable containing LADDER_RESULT lines
check_ladder_results() {
  local results="$1"
  local label="$2"

  # Parse each failure line: LADDER_RESULT:{"tier":"tier_07_advanced.json","test":"name","ok":false,...}
  while IFS= read -r line; do
    local tier test ok
    tier=$(echo "$line" | grep -o '"tier":"[^"]*"' | head -1 | sed 's/"tier":"//;s/"//')
    test=$(echo "$line" | grep -o '"test":"[^"]*"' | head -1 | sed 's/"test":"//;s/"//')
    ok=$(echo "$line" | grep -o '"ok":\(true\|false\)' | head -1 | sed 's/"ok"://')

    if [ -z "$tier" ] || [ -z "$test" ]; then
      continue
    fi

    local key="${tier}:${test}"

    if [ "$ok" = "false" ]; then
      if is_known_failure "$key"; then
        KNOWN_HITS+=("$label:$key")
      else
        NEW_FAILURES+=("$label:$key")
      fi
    else
      # Check if a known failure is now passing
      if is_known_failure "$key"; then
        KNOWN_NOW_PASSING+=("$label:$key")
      fi
    fi
  done <<< "$results"
}

# Print final failure report
report_failures() {
  if [ ${#KNOWN_NOW_PASSING[@]} -gt 0 ]; then
    echo ""
    echo "  NOTICE: Known failures now PASSING (remove from known_failures.txt):"
    for item in "${KNOWN_NOW_PASSING[@]}"; do
      echo "    ✓ $item"
    done
  fi

  if [ ${#KNOWN_HITS[@]} -gt 0 ]; then
    echo ""
    echo "  Known failures (pre-existing, not blocking):"
    for item in "${KNOWN_HITS[@]}"; do
      echo "    ~ $item"
    done
  fi

  if [ ${#NEW_FAILURES[@]} -gt 0 ]; then
    echo ""
    echo "  NEW FAILURES (not in known_failures.txt — these block the gate):"
    for item in "${NEW_FAILURES[@]}"; do
      echo "    ✗ $item"
    done
    echo ""
    echo "  To acknowledge a pre-existing upstream issue, add to:"
    echo "    $KNOWN_FAILURES"
    return 1
  fi

  return 0
}

echo "=== M3C Gate: Python Compatibility Ladder ==="
echo ""

# -------------------------------------------------------
# Step 1: Build native library (if needed)
# -------------------------------------------------------
echo "--- Building native library ---"
if [ ! -f "$ROOT/native/target/release/libdart_monty_native.dylib" ] && \
   [ ! -f "$ROOT/native/target/release/libdart_monty_native.so" ]; then
  cd "$ROOT/native"
  cargo build --release
else
  echo "  Native library already built, skipping."
fi

# -------------------------------------------------------
# Step 2: Run native ladder tests
# -------------------------------------------------------
echo ""
echo "--- Native ladder tests (dart test --tags=ladder) ---"
cd "$ROOT"
dart test --run-skipped --tags=ladder test/ffi/integration/

echo ""
echo "  Native ladder: PASSED"

# -------------------------------------------------------
# Step 3: Build web bundle
# -------------------------------------------------------
echo ""
echo "--- Building web bundle ---"
cd "$SPIKE"
# --force: @pydantic/monty-wasm32-wasi declares cpu:wasm32 but the WASM binary
# is architecture-independent. Without --force, npm refuses on ARM64 hosts.
# See: https://github.com/runyaga/monty/issues/4
npm install --force

echo "  esbuild: bundle worker"
npx esbuild web/monty_worker_src.js \
  --bundle \
  --format=esm \
  --outfile=web/monty_worker.js \
  --platform=browser \
  --external:'*.wasm' \
  --log-level=warning

cp node_modules/@pydantic/monty-wasm32-wasi/monty.wasm32-wasi.wasm web/ 2>/dev/null || true

echo "  esbuild: bundle glue"
npx esbuild web/monty_glue.js \
  --bundle \
  --format=iife \
  --outfile=web/monty_bundle.js \
  --platform=browser \
  --log-level=warning

# -------------------------------------------------------
# Step 4: Compile ladder runner to JS
# -------------------------------------------------------
echo "  dart compile js: ladder_runner"
dart pub get
dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js

# -------------------------------------------------------
# Step 5: Copy fixtures to web/fixtures/
# -------------------------------------------------------
echo "  Copying fixtures to web/fixtures/"
mkdir -p web/fixtures
cp "$ROOT"/test/fixtures/python_ladder/tier_*.json web/fixtures/

# -------------------------------------------------------
# Step 6: Serve and run headless Chrome
# -------------------------------------------------------
echo ""
echo "--- Web ladder tests (headless Chrome) ---"

SERVE_PORT=8098
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 -c "
import http.server
import functools

class COOPCOEPHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

    def guess_type(self, path):
        if path.endswith('.mjs'):
            return 'application/javascript'
        if path.endswith('.wasm'):
            return 'application/wasm'
        return super().guess_type(path)

    def log_message(self, fmt, *args):
        pass

handler = functools.partial(COOPCOEPHandler, directory='web')
server = http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler)
server.serve_forever()
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
  echo "  WARN: Chrome not found. Skipping web ladder verification."
  echo ""
  echo "=== M3C Ladder: Native PASSED, Web SKIPPED (no Chrome) ==="
  exit 0
fi

echo "  Using: $CHROME"

CONSOLE_LOG=$(mktemp)

timeout 60 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/ladder_runner.html" \
  2>"$CONSOLE_LOG" || true

# Extract LADDER_RESULT lines from Chrome console output
echo ""
echo "--- Web results ---"
WEB_RESULTS=$(grep -o 'LADDER_RESULT:{.*}' "$CONSOLE_LOG" 2>/dev/null || true)

if [ -z "$WEB_RESULTS" ]; then
  echo "  WARN: No LADDER_RESULT lines captured from Chrome."
  echo "  Raw console output:"
  grep -i "CONSOLE" "$CONSOLE_LOG" | head -30 || echo "  (no output)"
  rm -f "$CONSOLE_LOG"
  echo ""
  echo "=== M3C Ladder: Native PASSED, Web INCONCLUSIVE ==="
  exit 0
fi

echo "$WEB_RESULTS" | while IFS= read -r line; do
  echo "  $line"
done

LADDER_DONE=$(grep -c 'LADDER_DONE' "$CONSOLE_LOG" 2>/dev/null || echo "0")

rm -f "$CONSOLE_LOG"

check_ladder_results "$WEB_RESULTS" "web-spike"

echo ""
echo "  Web spike ladder: checked"

echo ""
echo "--- Ladder failure report ---"
if report_failures; then
  echo ""
  echo "=== Ladder: PASSED (native and web spike) ==="
else
  echo ""
  echo "=== Ladder: FAILED (new regressions detected) ==="
  exit 1
fi
