#!/usr/bin/env bash
# =============================================================================
# M3B Web Spike — Build, Serve, and Verify
# =============================================================================
# Builds the web spike (npm install, esbuild bundle, dart compile js),
# serves with COOP/COEP headers, and verifies in headless Chrome.
#
# Usage: bash tool/test_web_spike.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SPIKE="$ROOT/spike/web_test"

echo "=== M3B Web Spike: Build & Verify ==="

# -------------------------------------------------------
# Step 1: npm install
# -------------------------------------------------------
echo "--- npm install ---"
cd "$SPIKE"
npm install

# -------------------------------------------------------
# Step 2: Bundle JS for browser
# -------------------------------------------------------
echo "--- esbuild: bundle worker (resolves npm imports) ---"
npx esbuild web/monty_worker_src.js \
  --bundle \
  --format=esm \
  --outfile=web/monty_worker.js \
  --platform=browser \
  --external:'*.wasm' \
  --log-level=info

# Patch bare specifier for sub-worker URL (esbuild can't resolve new URL() imports)
sed -i.bak 's|new URL("@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"|new URL("./wasi-worker-browser.mjs"|g' \
  web/monty_worker.js && rm -f web/monty_worker.js.bak

# Copy WASI sub-worker to web/ (needed at runtime by the Worker)
cp node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs web/ 2>/dev/null || true

echo "--- esbuild: bundle glue (IIFE for main thread) ---"
npx esbuild web/monty_glue.js \
  --bundle \
  --format=iife \
  --outfile=web/monty_bundle.js \
  --platform=browser \
  --log-level=info

# -------------------------------------------------------
# Step 3: dart pub get + compile to JS
# -------------------------------------------------------
echo "--- dart pub get ---"
dart pub get

echo "--- dart compile js ---"
dart compile js bin/main.dart -o web/main.dart.js

# -------------------------------------------------------
# Step 4: Serve with COOP/COEP headers
# -------------------------------------------------------
echo "--- Starting web server with COOP/COEP headers ---"

# Use Python's http.server with custom headers via a small wrapper
SERVE_PORT=8099
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Python script that serves with COOP/COEP headers
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
        pass  # suppress request logs

handler = functools.partial(COOPCOEPHandler, directory='web')
server = http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler)
server.serve_forever()
" &
SERVE_PID=$!

# Wait for server to be ready
sleep 1

echo "  Server running on http://127.0.0.1:$SERVE_PORT (PID $SERVE_PID)"

# -------------------------------------------------------
# Step 5: Headless Chrome verification
# -------------------------------------------------------
echo "--- Headless Chrome verification ---"

# Detect Chrome binary
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
  echo "  WARN: Chrome not found. Skipping headless verification."
  echo "  Open http://127.0.0.1:$SERVE_PORT in a browser manually."
  echo "  Press Ctrl+C to stop the server."
  wait "$SERVE_PID"
  exit 0
fi

echo "  Using: $CHROME"

# Run headless Chrome with real timeout (virtual-time-budget freezes Worker timers)
CONSOLE_LOG=$(mktemp)

timeout 30 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT" \
  2>"$CONSOLE_LOG" || true

echo "--- Console output ---"
# Extract console messages from Chrome stderr log
grep -i "CONSOLE" "$CONSOLE_LOG" | head -50 || echo "(no console output captured)"
rm -f "$CONSOLE_LOG"

echo ""
echo "=== M3B Web Spike Complete ==="
echo "Review console output above for GO/NO-GO decision."
echo "For interactive testing: http://127.0.0.1:$SERVE_PORT"
