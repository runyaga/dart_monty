#!/usr/bin/env bash
# =============================================================================
# Web Example Runner
# =============================================================================
# Stages the dart_monty_core WASM/JS bridge assets next to the compiled
# Dart demo, then starts a COOP/COEP server.
#
# Usage:
#   bash example/web/run.sh
#
# The assets are pulled from the dart_monty_core package. Set
# DART_MONTY_CORE_DIR to an explicit checkout path when working on
# unreleased core changes; otherwise the script resolves the pub cache.
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
EXAMPLE="$ROOT/example/web"
WEB_DIR="$EXAMPLE/web"
FIXTURES_SRC="$ROOT/test/fixtures/python_ladder"

echo "=== dart_monty Web Example ==="

# ── Step 1: Locate dart_monty_core assets ────────────────────────────────
cd "$EXAMPLE"
dart pub get >/dev/null
if [ -n "${DART_MONTY_CORE_DIR:-}" ] && [ -d "$DART_MONTY_CORE_DIR/lib/assets" ]; then
  CORE_ASSETS="$DART_MONTY_CORE_DIR/lib/assets"
  echo "--- Using DART_MONTY_CORE_DIR: $CORE_ASSETS ---"
else
  # Resolve dart_monty_core's root from package_config.json (works for path,
  # git, and hosted deps; `dart pub cache dir` was removed in newer SDKs).
  CORE_ROOT=$(python3 - <<'PY'
import json, urllib.parse
try:
    cfg = json.load(open(".dart_tool/package_config.json"))
except OSError:
    raise SystemExit(0)
for p in cfg.get("packages", []):
    if p["name"] == "dart_monty_core":
        print(urllib.parse.unquote(urllib.parse.urlparse(p["rootUri"]).path))
        break
PY
)
  CORE_ASSETS="${CORE_ROOT%/}/lib/assets"
  if [ ! -d "$CORE_ASSETS" ]; then
    echo "FATAL: could not locate dart_monty_core assets ($CORE_ASSETS)." >&2
    echo "  Set DART_MONTY_CORE_DIR to a local checkout." >&2
    exit 1
  fi
  echo "--- Using resolved core: $CORE_ASSETS ---"
fi

# ── Step 2: Copy assets to web dir ───────────────────────────────────────
echo ""
echo "--- Copying assets ---"
cp "$CORE_ASSETS/dart_monty_core_bridge.js" "$WEB_DIR/"
cp "$CORE_ASSETS/dart_monty_core_worker.js" "$WEB_DIR/"
cp "$CORE_ASSETS/dart_monty_core_native.wasm" "$WEB_DIR/"
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
dart compile js bin/visualizer.dart -o "$WEB_DIR/visualizer.dart.js"
echo "  Compiled: web/visualizer.dart.js"
dart compile js bin/vfs_demo.dart -o "$WEB_DIR/vfs_demo.dart.js"
echo "  Compiled: web/vfs_demo.dart.js"
dart compile js bin/repl_demo.dart -o "$WEB_DIR/repl_demo.dart.js"
echo "  Compiled: web/repl_demo.dart.js"
dart compile js bin/agent_demo.dart -o "$WEB_DIR/agent_demo.dart.js"
echo "  Compiled: web/agent_demo.dart.js"
dart compile js bin/async_matrix_demo.dart -o "$WEB_DIR/async_matrix_demo.dart.js"
echo "  Compiled: web/async_matrix_demo.dart.js"

# ── Step 5: Start COOP/COEP server ──────────────────────────────────────
PORT=8088
cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Clean up copied files
  rm -f "$WEB_DIR/dart_monty_core_bridge.js" \
        "$WEB_DIR/dart_monty_core_worker.js" \
        "$WEB_DIR/dart_monty_core_native.wasm" \
        "$WEB_DIR/main.dart.js" \
        "$WEB_DIR/main.dart.js.deps" \
        "$WEB_DIR/main.dart.js.map" \
        "$WEB_DIR/ladder_showcase.dart.js" \
        "$WEB_DIR/ladder_showcase.dart.js.deps" \
        "$WEB_DIR/ladder_showcase.dart.js.map" \
        "$WEB_DIR/visualizer.dart.js" \
        "$WEB_DIR/visualizer.dart.js.deps" \
        "$WEB_DIR/visualizer.dart.js.map" \
        "$WEB_DIR/vfs_demo.dart.js" \
        "$WEB_DIR/vfs_demo.dart.js.deps" \
        "$WEB_DIR/vfs_demo.dart.js.map" \
        "$WEB_DIR/repl_demo.dart.js" \
        "$WEB_DIR/repl_demo.dart.js.deps" \
        "$WEB_DIR/repl_demo.dart.js.map" \
        "$WEB_DIR/agent_demo.dart.js" \
        "$WEB_DIR/agent_demo.dart.js.deps" \
        "$WEB_DIR/agent_demo.dart.js.map" \
        "$WEB_DIR/async_matrix_demo.dart.js" \
        "$WEB_DIR/async_matrix_demo.dart.js.deps" \
        "$WEB_DIR/async_matrix_demo.dart.js.map"
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
echo "  Home:       http://localhost:$PORT/"
echo "  Demo:       http://localhost:$PORT/demo.html"
echo "  Ladder:     http://localhost:$PORT/ladder.html"
echo "  Visualizer: http://localhost:$PORT/visualizer.html"
echo "  VFS:        http://localhost:$PORT/vfs.html"
echo "  Agent:      http://localhost:$PORT/agent.html"
echo "  Async:      http://localhost:$PORT/async_matrix.html"
echo "  Press Ctrl+C to stop."
echo ""

# Open browser (macOS)
if command -v open &>/dev/null; then
  open "http://localhost:$PORT/"
fi

wait "$SERVER_PID"
