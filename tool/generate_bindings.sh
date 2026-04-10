#!/usr/bin/env bash
# =============================================================================
# Generate FFI bindings for dart_monty
# =============================================================================
# Runs dart run ffigen in the root package to regenerate C bindings.
# Output: lib/src/ffi/generated/dart_monty_bindings.dart
# Usage: bash tool/generate_bindings.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "--- dart pub get ---"
dart pub get

echo "--- dart run ffigen ---"
dart run ffigen --config ffigen.yaml

echo "=== Bindings generated ==="
