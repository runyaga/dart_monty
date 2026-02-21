#!/usr/bin/env bash
# =============================================================================
# M2 Gate Script — Rust C FFI Layer + WASM Build
# =============================================================================
# Validates: fmt, clippy, test, release build, symbol export, WASM build
# Usage: bash tool/test_m2.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/native"

echo "=== M2 Gate: native/ ==="

echo "--- cargo fmt --check ---"
cargo fmt --check

echo "--- cargo clippy -- -D warnings ---"
cargo clippy -- -D warnings

echo "--- cargo test ---"
cargo test

echo "--- cargo tarpaulin (90% coverage gate) ---"
if ! command -v cargo-tarpaulin &>/dev/null; then
    echo "Installing cargo-tarpaulin..."
    cargo install cargo-tarpaulin
fi
OUTPUT=$(cargo tarpaulin 2>&1)
echo "$OUTPUT"
PCT=$(echo "$OUTPUT" | grep -oE '[0-9]+\.[0-9]+% coverage' | grep -oE '[0-9]+\.[0-9]+' | tail -1 || echo "0")
echo "Coverage: ${PCT}%"
WHOLE=${PCT%%.*}
if [ "${WHOLE:-0}" -lt 90 ]; then
    echo "FAIL: Coverage ${PCT}% < 90% minimum."
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

echo "=== M2 Gate PASSED ==="
