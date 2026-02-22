#!/usr/bin/env bash
# =============================================================================
# M3C Gate Script — Cross-Path Parity
# =============================================================================
# Runs both native and web paths with JSONL output, diffs results.
# Exit 1 if any non-skipped fixture produces different results.
#
# Usage: bash tool/test_cross_path_parity.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SPIKE="$ROOT/spike/web_test"
FFI_PKG="$ROOT/packages/dart_monty_ffi"
WASM_PKG="$ROOT/packages/dart_monty_wasm"

NATIVE_JSONL="/tmp/parity_native.jsonl"
WEB_JSONL="/tmp/parity_web.jsonl"
WASM_JSONL="/tmp/parity_wasm.jsonl"

echo "=== M3C Gate: Cross-Path Parity ==="
echo ""

# -------------------------------------------------------
# Step 1: Run native JSONL runner
# -------------------------------------------------------
echo "--- Running native ladder runner ---"
cd "$FFI_PKG"
dart pub get

DART_MONTY_LIB_PATH="$ROOT/native/target/release/libdart_monty_native.$(uname -s | grep -qi darwin && echo dylib || echo so)" \
DYLD_LIBRARY_PATH="$ROOT/native/target/release" \
LD_LIBRARY_PATH="$ROOT/native/target/release" \
  dart test/integration/python_ladder_runner.dart > "$NATIVE_JSONL"

echo "  Native results: $NATIVE_JSONL"
echo "  Lines: $(wc -l < "$NATIVE_JSONL" | tr -d ' ')"

# -------------------------------------------------------
# Step 2: Build and run web ladder runner
# -------------------------------------------------------
echo ""
echo "--- Building web ladder runner ---"
cd "$SPIKE"
npm install --silent

npx esbuild web/monty_worker_src.js \
  --bundle --format=esm \
  --outfile=web/monty_worker.js \
  --platform=browser --external:'*.wasm' \
  --log-level=warning

sed -i.bak 's|new URL("@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"|new URL("./wasi-worker-browser.mjs"|g' \
  web/monty_worker.js && rm -f web/monty_worker.js.bak

cp node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs web/ 2>/dev/null || true

npx esbuild web/monty_glue.js \
  --bundle --format=iife \
  --outfile=web/monty_bundle.js \
  --platform=browser --log-level=warning

dart pub get
dart compile js bin/ladder_runner.dart -o web/ladder_runner.dart.js

mkdir -p web/fixtures
cp "$ROOT"/test/fixtures/python_ladder/tier_*.json web/fixtures/

echo ""
echo "--- Running web ladder runner (headless Chrome) ---"

SERVE_PORT=8097
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
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
handler = functools.partial(H, directory='web')
http.server.HTTPServer(('127.0.0.1', $SERVE_PORT), handler).serve_forever()
" &
SERVE_PID=$!
sleep 1

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
  echo "  WARN: Chrome not found. Cannot run web path."
  echo "=== Parity: SKIPPED (no Chrome) ==="
  exit 0
fi

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

# Extract LADDER_RESULT lines
grep -o 'LADDER_RESULT:{.*}' "$CONSOLE_LOG" 2>/dev/null | \
  sed 's/^LADDER_RESULT://' > "$WEB_JSONL" || true

rm -f "$CONSOLE_LOG"

echo "  Web results: $WEB_JSONL"
echo "  Lines: $(wc -l < "$WEB_JSONL" | tr -d ' ')"

# -------------------------------------------------------
# Step 3: Compare results
# -------------------------------------------------------
echo ""
echo "--- Comparing results ---"

python3 -c "
import json, sys

def load_results(path):
    results = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            results[obj['id']] = obj
    return results

native = load_results('$NATIVE_JSONL')
web = load_results('$WEB_JSONL')

all_ids = sorted(set(native.keys()) | set(web.keys()))

mismatches = 0
matches = 0
skipped = 0

for fid in all_ids:
    n = native.get(fid)
    w = web.get(fid)

    if w and w.get('skipped'):
        print(f'  #{fid:2d}: SKIPPED (nativeOnly)')
        skipped += 1
        continue

    if n is None:
        print(f'  #{fid:2d}: MISMATCH — missing from native')
        mismatches += 1
        continue

    if w is None:
        print(f'  #{fid:2d}: MISMATCH — missing from web')
        mismatches += 1
        continue

    n_ok = n.get('ok')
    w_ok = w.get('ok')
    n_val = n.get('value') if n_ok else n.get('error')
    w_val = w.get('value') if w_ok else w.get('error')

    # Normalize: compare JSON-encoded values
    if json.dumps(n_val, sort_keys=True) == json.dumps(w_val, sort_keys=True) and n_ok == w_ok:
        print(f'  #{fid:2d}: MATCH (value={json.dumps(n_val)[:60]})')
        matches += 1
    else:
        print(f'  #{fid:2d}: MISMATCH')
        print(f'         native: ok={n_ok} val={json.dumps(n_val)[:80]}')
        print(f'         web:    ok={w_ok} val={json.dumps(w_val)[:80]}')
        mismatches += 1

print()
print(f'  Summary: {matches} match, {mismatches} mismatch, {skipped} skipped')

if mismatches > 0:
    sys.exit(1)
"

echo ""
echo "  Native vs Web spike: PASSED"

# -------------------------------------------------------
# Step 4: Build and run WASM package ladder runner
# -------------------------------------------------------
if [ -d "$WASM_PKG/js" ]; then
  echo ""
  echo "--- Building WASM package ladder runner ---"
  cd "$WASM_PKG/js"
  npm install --silent
  npm run build 2>&1 | tail -1

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

  echo ""
  echo "--- Running WASM package ladder runner (headless Chrome) ---"

  # Kill previous server
  kill "$SERVE_PID" 2>/dev/null || true
  wait "$SERVE_PID" 2>/dev/null || true

  SERVE_PORT=8095
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

  WASM_CONSOLE=$(mktemp)

  timeout 60 "$CHROME" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    --enable-logging=stderr \
    --v=0 \
    "http://127.0.0.1:$SERVE_PORT/ladder.html" \
    2>"$WASM_CONSOLE" || true

  grep -o 'LADDER_RESULT:{.*}' "$WASM_CONSOLE" 2>/dev/null | \
    sed 's/^LADDER_RESULT://' > "$WASM_JSONL" || true

  rm -f "$WASM_CONSOLE"

  echo "  WASM results: $WASM_JSONL"
  echo "  Lines: $(wc -l < "$WASM_JSONL" | tr -d ' ')"

  # Clean up copied assets
  rm -f "$WASM_INTEG/dart_monty_bridge.js" \
        "$WASM_INTEG/dart_monty_worker.js" \
        "$WASM_INTEG/wasi-worker-browser.mjs" \
        "$WASM_INTEG/"*.wasm \
        "$WASM_INTEG/ladder_runner.dart.js" \
        "$WASM_INTEG/ladder_runner.dart.js.deps" \
        "$WASM_INTEG/ladder_runner.dart.js.map"
  rm -rf "$WASM_INTEG/fixtures"

  # -------------------------------------------------------
  # Step 5: Compare WASM package vs native
  # -------------------------------------------------------
  echo ""
  echo "--- Comparing WASM package vs native ---"

  python3 -c "
import json, sys

def load_results(path):
    results = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            results[obj['id']] = obj
    return results

native = load_results('$NATIVE_JSONL')
wasm = load_results('$WASM_JSONL')

all_ids = sorted(set(native.keys()) | set(wasm.keys()))

mismatches = 0
matches = 0
skipped = 0

for fid in all_ids:
    n = native.get(fid)
    w = wasm.get(fid)

    if w and w.get('skipped'):
        print(f'  #{fid:2d}: SKIPPED (nativeOnly)')
        skipped += 1
        continue

    if n is None:
        print(f'  #{fid:2d}: MISMATCH — missing from native')
        mismatches += 1
        continue

    if w is None:
        print(f'  #{fid:2d}: MISMATCH — missing from wasm-pkg')
        mismatches += 1
        continue

    n_ok = n.get('ok')
    w_ok = w.get('ok')
    n_val = n.get('value') if n_ok else n.get('error')
    w_val = w.get('value') if w_ok else w.get('error')

    if json.dumps(n_val, sort_keys=True) == json.dumps(w_val, sort_keys=True) and n_ok == w_ok:
        print(f'  #{fid:2d}: MATCH (value={json.dumps(n_val)[:60]})')
        matches += 1
    else:
        print(f'  #{fid:2d}: MISMATCH')
        print(f'         native:   ok={n_ok} val={json.dumps(n_val)[:80]}')
        print(f'         wasm-pkg: ok={w_ok} val={json.dumps(w_val)[:80]}')
        mismatches += 1

print()
print(f'  Summary: {matches} match, {mismatches} mismatch, {skipped} skipped')

if mismatches > 0:
    sys.exit(1)
"
  echo ""
  echo "  Native vs WASM package: PASSED"
else
  echo ""
  echo "  WASM package not found, skipping WASM parity."
fi

echo ""
echo "=== Parity: PASSED ==="
