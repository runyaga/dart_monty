#!/usr/bin/env bash
# =============================================================================
# M3A Gate Script — Native FFI Package
# =============================================================================
# Validates: pub get, format, analyze, test, coverage >= 90%
# Usage: bash tool/test_m3a.sh
# =============================================================================
set -euo pipefail

PKG="packages/dart_monty_ffi"
MIN_COVERAGE=90

cd "$(git rev-parse --show-toplevel)"

echo "=== M3A Gate: $PKG ==="

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

echo "=== M3A Gate PASSED (${PCT}% coverage) ==="
