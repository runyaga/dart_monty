#!/usr/bin/env bash
# =============================================================================
# Native Example Runner
# =============================================================================
# Builds the Rust native library (if needed) and runs the Dart example.
#
# Usage: bash example/native/run.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
NATIVE="$ROOT/native"
EXAMPLE="$ROOT/example/native"

echo "=== dart_monty Native Example ==="

# Detect platform library extension
case "$(uname -s)" in
  Darwin*) LIB_EXT="dylib" ;;
  Linux*)  LIB_EXT="so" ;;
  *)       LIB_EXT="so" ;;
esac

LIB_PATH="$NATIVE/target/release/libdart_monty_native.$LIB_EXT"

# ── Step 1: Build Rust library (if missing) ──────────────────────────────
if [ ! -f "$LIB_PATH" ]; then
  echo ""
  echo "--- Building native library ---"
  cd "$NATIVE"
  cargo build --release
  echo "  Built: $LIB_PATH"
fi

# ── Step 2: Run Dart example ─────────────────────────────────────────────
echo ""
cd "$EXAMPLE"
dart pub get
echo ""
DART_MONTY_LIB_PATH="$LIB_PATH" dart run bin/main.dart
