#!/usr/bin/env bash
# =============================================================================
# Gate Script — WASM Tests
# =============================================================================
# Runs WASM unit tests from the root package.
# Usage: bash tool/test_wasm.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== WASM Tests ==="
dart test test/wasm/
echo "=== WASM Tests PASSED ==="
