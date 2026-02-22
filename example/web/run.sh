#!/usr/bin/env bash
# =============================================================================
# Web Example Runner
# =============================================================================
# Builds the JS bridge, compiles Dart to JS, starts a COOP/COEP server,
# and opens the example in your default browser.
#
# Usage: bash example/web/run.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
WASM_PKG="$ROOT/packages/dart_monty_wasm"
EXAMPLE="$ROOT/example/web"
WEB_DIR="$EXAMPLE/web"
FIXTURES_SRC="$ROOT/test/fixtures/python_ladder"

echo "=== dart_monty Web Example ==="

# ── Step 1: Build JS bridge (if assets missing) ─────────────────────────
if [ ! -f "$WASM_PKG/assets/dart_monty_bridge.js" ]; then
  echo ""
  echo "--- Building JS bridge ---"
  cd "$WASM_PKG/js"
  npm install
  npm run build
  echo "  JS build: OK"
fi

# ── Step 2: Copy assets to web dir ───────────────────────────────────────
echo ""
echo "--- Copying assets ---"
cp "$WASM_PKG/assets/dart_monty_bridge.js" "$WEB_DIR/"
cp "$WASM_PKG/assets/dart_monty_worker.js" "$WEB_DIR/"
cp "$WASM_PKG/assets/wasi-worker-browser.mjs" "$WEB_DIR/"
cp "$WASM_PKG/assets/"*.wasm "$WEB_DIR/"
echo "  Assets copied."

# ── Step 3: Copy fixture files for ladder showcase ───────────────────────
echo ""
echo "--- Copying fixtures ---"
mkdir -p "$WEB_DIR/fixtures"
cp "$FIXTURES_SRC"/tier_*.json "$WEB_DIR/fixtures/"
echo "  Fixtures copied."

# ── Step 4: Compile Dart to JS ───────────────────────────────────────────
echo ""
echo "--- Compiling Dart to JS ---"
cd "$EXAMPLE"
dart pub get
dart compile js bin/main.dart -o "$WEB_DIR/main.dart.js"
echo "  Compiled: web/main.dart.js"
dart compile js bin/ladder_showcase.dart -o "$WEB_DIR/ladder_showcase.dart.js"
echo "  Compiled: web/ladder_showcase.dart.js"

# ── Step 5: Start COOP/COEP server ──────────────────────────────────────
PORT=8088
cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Clean up copied files
  rm -f "$WEB_DIR/dart_monty_bridge.js" \
        "$WEB_DIR/dart_monty_worker.js" \
        "$WEB_DIR/wasi-worker-browser.mjs" \
        "$WEB_DIR/"*.wasm \
        "$WEB_DIR/main.dart.js" \
        "$WEB_DIR/main.dart.js.deps" \
        "$WEB_DIR/main.dart.js.map" \
        "$WEB_DIR/ladder_showcase.dart.js" \
        "$WEB_DIR/ladder_showcase.dart.js.deps" \
        "$WEB_DIR/ladder_showcase.dart.js.map"
  rm -rf "$WEB_DIR/fixtures"
}
trap cleanup EXIT

echo ""
echo "--- Starting server on http://localhost:$PORT ---"
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

handler = functools.partial(H, directory='$WEB_DIR')
http.server.HTTPServer(('127.0.0.1', $PORT), handler).serve_forever()
" &
SERVER_PID=$!
sleep 1

echo ""
echo "  Home:    http://localhost:$PORT/"
echo "  Demo:    http://localhost:$PORT/demo.html"
echo "  Ladder:  http://localhost:$PORT/ladder.html"
echo "  Press Ctrl+C to stop."
echo ""

# Open browser (macOS)
if command -v open &>/dev/null; then
  open "http://localhost:$PORT/"
fi

wait "$SERVER_PID"
