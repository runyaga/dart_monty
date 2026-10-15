#!/usr/bin/env bash
# =============================================================================
# Native Example Runner
# =============================================================================
# Runs the native Dart examples. Python runs in dart_monty_core's worker
# process; set DART_MONTY_WORKER to a worker executable, or leave it unset
# for core's own discovery.
#
# Usage: bash example/native/run.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
EXAMPLE="$ROOT/example/native"

echo "=== dart_monty Native Example ==="

cd "$EXAMPLE"
dart pub get
echo ""
dart run bin/main.dart

echo ""
echo "--- Async/sync matrix demo ---"
dart run bin/async_matrix_demo.dart

echo ""
echo "--- Type-check demo ---"
cd "$ROOT/example"
dart pub get >/dev/null
dart run type_check_demo.dart
