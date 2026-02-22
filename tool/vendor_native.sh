#!/usr/bin/env bash
set -euo pipefail

# Build native libraries and copy them into dart_monty_desktop platform dirs.
#
# Usage:
#   bash tool/vendor_native.sh              # build for current platform
#   bash tool/vendor_native.sh --all        # build for all platforms (CI only)
#
# After running, the binaries are at:
#   packages/dart_monty_desktop/macos/libdart_monty_native.dylib
#   packages/dart_monty_desktop/linux/libdart_monty_native.so

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP_DIR="$ROOT_DIR/packages/dart_monty_desktop"
NATIVE_DIR="$ROOT_DIR/native"

echo "==> Building native library..."
cd "$NATIVE_DIR"
cargo build --release

OS="$(uname -s)"
case "$OS" in
  Darwin)
    SRC="$NATIVE_DIR/target/release/libdart_monty_native.dylib"
    DST="$DESKTOP_DIR/macos/libdart_monty_native.dylib"
    echo "==> Copying $SRC -> $DST"
    cp "$SRC" "$DST"
    echo "    macOS binary vendored."
    ;;
  Linux)
    SRC="$NATIVE_DIR/target/release/libdart_monty_native.so"
    DST="$DESKTOP_DIR/linux/libdart_monty_native.so"
    mkdir -p "$DESKTOP_DIR/linux"
    echo "==> Copying $SRC -> $DST"
    cp "$SRC" "$DST"
    echo "    Linux binary vendored."
    ;;
  *)
    echo "ERROR: Unsupported OS: $OS"
    exit 1
    ;;
esac

echo ""
echo "==> Done. Vendored binaries:"
ls -lh "$DESKTOP_DIR/macos/libdart_monty_native.dylib" 2>/dev/null || true
ls -lh "$DESKTOP_DIR/linux/libdart_monty_native.so" 2>/dev/null || true
