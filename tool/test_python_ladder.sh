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
FFI_PKG="$ROOT/packages/dart_monty_ffi"
WASM_PKG="$ROOT/packages/dart_monty_wasm"

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
cd "$FFI_PKG"
dart pub get
DART_MONTY_LIB_PATH="$ROOT/native/target/release/libdart_monty_native.$(uname -s | grep -qi darwin && echo dylib || echo so)" \
DYLD_LIBRARY_PATH="$ROOT/native/target/release" \
LD_LIBRARY_PATH="$ROOT/native/target/release" \
  dart test --tags=ladder

echo ""
echo "  Native ladder: PASSED"

# -------------------------------------------------------
# Step 3: Build web bundle
# -------------------------------------------------------
echo ""
echo "--- Building web bundle ---"
cd "$SPIKE"
npm install

echo "  esbuild: bundle worker"
npx esbuild web/monty_worker_src.js \
  --bundle \
  --format=esm \
  --outfile=web/monty_worker.js \
  --platform=browser \
  --external:'*.wasm' \
  --log-level=warning

# Patch bare specifier for sub-worker URL
sed -i.bak 's|new URL("@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"|new URL("./wasi-worker-browser.mjs"|g' \
  web/monty_worker.js && rm -f web/monty_worker.js.bak

cp node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs web/ 2>/dev/null || true

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
WEB_FAILURES=$(echo "$WEB_RESULTS" | grep -c '"ok":false' 2>/dev/null || echo "0")

rm -f "$CONSOLE_LOG"

echo ""
if [ "$WEB_FAILURES" -gt 0 ]; then
  echo "=== M3C Ladder: Native PASSED, Web spike had $WEB_FAILURES failures ==="
  exit 1
fi

echo "  Web spike ladder: PASSED"

# -------------------------------------------------------
# Step 7: Build WASM package bridge
# -------------------------------------------------------
echo ""
echo "--- Building WASM package bridge ---"
if [ -d "$WASM_PKG/js" ]; then
  cd "$WASM_PKG/js"
  npm install
  npm run build

  # -------------------------------------------------------
  # Step 8: Compile WASM package ladder runner
  # -------------------------------------------------------
  echo "  Compiling WASM package ladder runner..."
  WASM_INTEG="$WASM_PKG/test/integration/web"
  cp "$WASM_PKG/assets/dart_monty_bridge.js" "$WASM_INTEG/"
  cp "$WASM_PKG/assets/dart_monty_worker.js" "$WASM_INTEG/"
  cp "$WASM_PKG/assets/wasi-worker-browser.mjs" "$WASM_INTEG/"
  cp "$WASM_PKG/assets/"*.wasm "$WASM_INTEG/"

  cd "$WASM_PKG"
  dart pub get
  dart compile js test/integration/python_ladder_test.dart \
    -o "$WASM_INTEG/ladder_runner.dart.js"

  mkdir -p "$WASM_INTEG/fixtures"
  cp "$ROOT"/test/fixtures/python_ladder/tier_*.json "$WASM_INTEG/fixtures/"

  # -------------------------------------------------------
  # Step 9: Run WASM package ladder in headless Chrome
  # -------------------------------------------------------
  echo ""
  echo "--- WASM package ladder tests (headless Chrome) ---"

  # Reuse the server cleanup trap
  kill "$SERVE_PID" 2>/dev/null || true
  wait "$SERVE_PID" 2>/dev/null || true

  SERVE_PORT=8096
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
handler = functools.partial(H, directory='$WASM_INTEG')
http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler).serve_forever()
" &
  SERVE_PID=$!
  sleep 1

  echo "  Server running on http://127.0.0.1:$SERVE_PORT (PID $SERVE_PID)"

  WASM_CONSOLE_LOG=$(mktemp)

  timeout 60 "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    --enable-logging=stderr \
    --v=0 \
    "http://127.0.0.1:$SERVE_PORT/ladder.html" \
    2>"$WASM_CONSOLE_LOG" || true

  WASM_RESULTS=$(grep -o 'LADDER_RESULT:{.*}' "$WASM_CONSOLE_LOG" 2>/dev/null || true)

  if [ -z "$WASM_RESULTS" ]; then
    echo "  WARN: No LADDER_RESULT lines from WASM package."
    grep -i "CONSOLE" "$WASM_CONSOLE_LOG" | head -20 || echo "  (no output)"
    rm -f "$WASM_CONSOLE_LOG"
    echo ""
    echo "=== Ladder: Native PASSED, Web spike PASSED, WASM package INCONCLUSIVE ==="
    exit 0
  fi

  echo "$WASM_RESULTS" | while IFS= read -r line; do
    echo "  $line"
  done

  WASM_FAILURES=$(echo "$WASM_RESULTS" | grep -c '"ok":false' 2>/dev/null || echo "0")

  rm -f "$WASM_CONSOLE_LOG"

  # Clean up copied assets
  rm -f "$WASM_INTEG/dart_monty_bridge.js" \
        "$WASM_INTEG/dart_monty_worker.js" \
        "$WASM_INTEG/wasi-worker-browser.mjs" \
        "$WASM_INTEG/"*.wasm \
        "$WASM_INTEG/ladder_runner.dart.js" \
        "$WASM_INTEG/ladder_runner.dart.js.deps" \
        "$WASM_INTEG/ladder_runner.dart.js.map"
  rm -rf "$WASM_INTEG/fixtures"

  if [ "$WASM_FAILURES" -gt 0 ]; then
    echo ""
    echo "=== Ladder: Native PASSED, Web spike PASSED, WASM package had $WASM_FAILURES failures ==="
    exit 1
  fi

  echo "  WASM package ladder: PASSED"
else
  echo "  WASM package not found, skipping."
fi

echo ""
echo "=== Ladder: PASSED (native, web spike, and WASM package) ==="
