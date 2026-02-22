#!/usr/bin/env bash
# =============================================================================
# Generate FFI bindings for dart_monty_ffi
# =============================================================================
# Runs dart run ffigen in the FFI package to regenerate C bindings.
# Usage: bash tool/generate_bindings.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/packages/dart_monty_ffi"

echo "--- dart pub get ---"
dart pub get

echo "--- dart run ffigen ---"
dart run ffigen --config ffigen.yaml

echo "=== Bindings generated ==="
