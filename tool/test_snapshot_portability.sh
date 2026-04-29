#!/usr/bin/env bash
# =============================================================================
# Snapshot round-trip — native gate
# =============================================================================
# Re-runs the integration test that exercises native snapshot round-trip.
# Cross-platform (native ↔ web) snapshot portability is not gated here;
# the binary format is not yet guaranteed stable across backends, see
# upstream pydantic/monty for tracking.
#
# Usage: bash tool/test_snapshot_portability.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

echo "=== Snapshot round-trip (native) ==="
cd "$ROOT"
dart pub get

if dart test --run-skipped --tags=integration --name="snapshot round-trip" 2>&1; then
  echo ""
  echo "=== Snapshot round-trip: PASSED ==="
else
  echo ""
  echo "=== Snapshot round-trip: FAILED ==="
  exit 1
fi
