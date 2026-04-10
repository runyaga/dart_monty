#!/usr/bin/env bash
# =============================================================================
# Gate Script — FFI Tests
# =============================================================================
# Runs FFI unit tests from the root package.
# Usage: bash tool/test_ffi.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== FFI Tests ==="
dart test test/ffi/
echo "=== FFI Tests PASSED ==="
