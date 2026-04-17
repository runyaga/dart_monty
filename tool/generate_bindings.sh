#!/usr/bin/env bash
# =============================================================================
# Generate FFI bindings for dart_monty
# =============================================================================
# Runs dart run ffigen in dart_monty_core to regenerate C bindings.
# Note: FFI bindings now live in dart_monty_core, not dart_monty.
# Usage: bash tool/generate_bindings.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "--- dart pub get ---"
dart pub get

echo "--- dart run ffigen ---"
dart run ffigen --config ffigen.yaml

echo "=== Bindings generated ==="
