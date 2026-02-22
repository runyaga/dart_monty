#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE="$ROOT/native"
DESKTOP="$ROOT/packages/dart_monty_desktop"

echo "=== Building native library ==="
cd "$NATIVE"
cargo build --release

OS="$(uname -s)"
case "$OS" in
  Darwin)
    SRC="$NATIVE/target/release/libdart_monty_native.dylib"
    DST="$DESKTOP/macos/libdart_monty_native.dylib"
    ;;
  Linux)
    SRC="$NATIVE/target/release/libdart_monty_native.so"
    DST="$DESKTOP/linux/libdart_monty_native.so"
    ;;
  *)
    echo "Unsupported OS: $OS" >&2; exit 1
    ;;
esac

echo "=== Copying $SRC -> $DST ==="
mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
echo "=== Done ==="
