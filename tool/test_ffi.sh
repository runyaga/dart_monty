#!/usr/bin/env bash
# =============================================================================
# Gate Script — Native FFI Package
# =============================================================================
# Validates: pub get, format, analyze, test, coverage >= 30%
# Note: Unit-test-only coverage is ~45%. Integration tests (which need
# the native library) cover the remaining paths. 30% threshold ensures
# unit tests don't regress while allowing the gate to pass without
# the native library present.
# Usage: bash tool/test_ffi.sh
# =============================================================================
set -euo pipefail

PKG="packages/dart_monty_ffi"
MIN_COVERAGE=30

cd "$(git rev-parse --show-toplevel)"

echo "=== FFI Gate: $PKG ==="

echo "--- dart pub get ---"
cd "$PKG"
dart pub get

echo "--- dart format --set-exit-if-changed . ---"
dart format --set-exit-if-changed .

echo "--- dart analyze --fatal-infos ---"
dart analyze --fatal-infos

echo "--- dart test --coverage=coverage ---"
dart test --coverage=coverage

echo "--- Generating LCOV report ---"
dart pub global run coverage:format_coverage \
  --lcov \
  --in=coverage \
  --out=coverage/lcov.info \
  --report-on=lib

# Extract line coverage percentage
TOTAL=$(grep -c '^DA:' coverage/lcov.info || true)
HIT=$(grep '^DA:' coverage/lcov.info | grep -cv ',0$' || true)

if [ "$TOTAL" -eq 0 ]; then
  echo "ERROR: No coverage data found."
  exit 1
fi

PCT=$(( HIT * 100 / TOTAL ))
echo "Coverage: $HIT/$TOTAL lines = ${PCT}%"

if [ "$PCT" -lt "$MIN_COVERAGE" ]; then
  echo "FAIL: Coverage ${PCT}% < ${MIN_COVERAGE}% minimum."
  exit 1
fi

echo "=== FFI Gate PASSED (${PCT}% coverage) ==="
