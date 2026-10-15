#!/usr/bin/env bash
# =============================================================================
# Gate Script — Platform Interface Tests
# =============================================================================
# Runs platform interface unit tests from the root package.
# Usage: bash tool/test_platform_interface.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Platform Interface Tests ==="
dart test --exclude-tags d1-pending test/platform/
echo "=== Platform Interface Tests PASSED ==="
