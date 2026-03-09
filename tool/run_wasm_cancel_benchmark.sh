#!/usr/bin/env bash
# =============================================================================
# Run WASM Cancel Benchmark in headless Chrome with COOP/COEP headers.
#
# Usage: bash tool/run_wasm_cancel_benchmark.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PKG="$ROOT/packages/dart_monty_wasm"
INTEG_WEB="$PKG/test/integration/web"
SERVE_PORT=8097

echo "=== WASM Cancel Benchmark ==="

# --- Ensure assets ---
if [ ! -f "$PKG/assets/dart_monty_bridge.js" ]; then
  echo "Building JS bridge..."
  cd "$PKG/js" && npm install && npm run build
fi

echo "Copying assets to $INTEG_WEB..."
cp "$PKG/assets/dart_monty_bridge.js" "$INTEG_WEB/"
cp "$PKG/assets/dart_monty_worker.js" "$INTEG_WEB/"
cp "$PKG/assets/wasi-worker-browser.mjs" "$INTEG_WEB/"
cp "$PKG/assets/"*.wasm "$INTEG_WEB/"

# --- Compile benchmark to JS ---
echo "Compiling cancel_benchmark.dart to JS..."
cd "$PKG"
dart pub get >/dev/null 2>&1
dart compile js test/integration/cancel_benchmark.dart \
  -o "$INTEG_WEB/cancel_benchmark.dart.js"

# --- COOP/COEP server ---
cleanup() {
  if [ -n "${SERVE_PID:-}" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -f "$INTEG_WEB/dart_monty_bridge.js" \
        "$INTEG_WEB/dart_monty_worker.js" \
        "$INTEG_WEB/wasi-worker-browser.mjs" \
        "$INTEG_WEB/"*.wasm \
        "$INTEG_WEB/cancel_benchmark.dart.js" \
        "$INTEG_WEB/cancel_benchmark.dart.js.deps" \
        "$INTEG_WEB/cancel_benchmark.dart.js.map"
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

echo "Server running on http://127.0.0.1:$SERVE_PORT (PID $SERVE_PID)"

# --- Detect Chrome ---
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
  echo "ERROR: Chrome not found. Cannot run WASM benchmark."
  exit 1
fi

echo "Using: $CHROME"
echo ""

# --- Run benchmark ---
BENCH_LOG=$(mktemp)

timeout 300 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/cancel_benchmark.html" \
  2>&1 | tee "$BENCH_LOG" &

CHROME_PID=$!

# Wait for BENCH_DONE or timeout
for i in $(seq 1 300); do
  if grep -q "BENCH_DONE" "$BENCH_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done

# Kill Chrome
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true

echo ""
echo "=== WASM Benchmark Output ==="
grep "BENCH_" "$BENCH_LOG" | sed 's/.*BENCH_/BENCH_/' || echo "No BENCH_ output found"

rm -f "$BENCH_LOG"
echo ""
echo "=== Done ==="
