#!/usr/bin/env bash
# =============================================================================
# Gate Script — Rust Native Crate (via dart_monty_core)
# =============================================================================
# dart_monty no longer owns the Rust crate — it lives in dart_monty_core.
# Resolves dart_monty_core's native/ directory from .dart_tool/package_config.json
# and runs all Rust quality checks there.
#
# Usage: bash tool/test_rust.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PACKAGE_CONFIG="$ROOT/.dart_tool/package_config.json"

if [ ! -f "$PACKAGE_CONFIG" ]; then
  echo "ERROR: .dart_tool/package_config.json not found — run 'dart pub get' first."
  exit 1
fi

# Resolve dart_monty_core's root from the package config.
CORE_ROOT=$(python3 - <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    cfg = json.load(f)
for pkg in cfg['packages']:
    if pkg['name'] == 'dart_monty_core':
        uri = pkg['rootUri']
        # Strip file:// prefix
        print(uri.removeprefix('file://'))
        sys.exit(0)
print('ERROR: dart_monty_core not found in package_config.json', file=sys.stderr)
sys.exit(1)
EOF
"$PACKAGE_CONFIG")

NATIVE="$CORE_ROOT/native"

if [ ! -d "$NATIVE" ]; then
  echo "SKIP: dart_monty_core/native/ not found at $NATIVE"
  echo "  (pre-built binary consumer path — no Rust source to gate)"
  exit 0
fi

cd "$NATIVE"
echo "=== Rust Gate: $NATIVE ==="

echo "--- cargo fmt --check ---"
cargo fmt --check

echo "--- cargo clippy -- -D warnings ---"
cargo clippy -- -D warnings

echo "--- cargo deny check ---"
if command -v cargo-deny &>/dev/null; then
  cargo deny check
else
  echo "SKIP: cargo-deny not installed (cargo install cargo-deny)"
fi

echo "--- cargo test ---"
cargo test

echo "--- cargo tarpaulin (70% coverage gate) ---"
if ! command -v cargo-tarpaulin &>/dev/null; then
    echo "Installing cargo-tarpaulin..."
    cargo install cargo-tarpaulin
fi
OUTPUT=$(cargo tarpaulin 2>&1)
echo "$OUTPUT"
PCT=$(echo "$OUTPUT" | grep -oE '[0-9]+\.[0-9]+% coverage' | grep -oE '[0-9]+\.[0-9]+' | tail -1 || echo "0")
echo "Coverage: ${PCT}%"
WHOLE=${PCT%%.*}
if [ "${WHOLE:-0}" -lt 70 ]; then
    echo "FAIL: Coverage ${PCT}% < 70% minimum."
    exit 1
fi

echo "--- cargo build --release ---"
cargo build --release

echo "--- Verify exported symbols ---"
if [[ "$(uname)" == "Darwin" ]]; then
    SYMBOLS=$(nm -gU target/release/libdart_monty_native.dylib | grep -c 'monty_' || true)
else
    SYMBOLS=$(nm -D target/release/libdart_monty_native.so | grep -c 'monty_' || true)
fi

if [ "$SYMBOLS" -lt 17 ]; then
    echo "FAIL: Expected >= 17 monty_* symbols, found $SYMBOLS"
    exit 1
fi
echo "Found $SYMBOLS monty_* symbols"

echo "--- cargo build --release --target wasm32-wasip1-threads ---"
cargo build --release --target wasm32-wasip1-threads

WASM="target/wasm32-wasip1-threads/release/dart_monty_native.wasm"
if [ ! -f "$WASM" ]; then
    echo "FAIL: WASM binary not found at $WASM"
    exit 1
fi
WASM_SIZE=$(wc -c < "$WASM" | tr -d ' ')
echo "WASM binary: $WASM_SIZE bytes"

echo "=== Rust Gate PASSED ==="
