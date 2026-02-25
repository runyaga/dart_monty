#!/usr/bin/env bash
# =============================================================================
# Gate Script — Platform Interface
# =============================================================================
# Validates: pub get, format, analyze, test, coverage >= 70%
# Usage: bash tool/test_platform_interface.sh
# =============================================================================
set -euo pipefail

PKG="packages/dart_monty_platform_interface"
MIN_COVERAGE=70

cd "$(git rev-parse --show-toplevel)"

echo "=== Markdown lint ==="
if command -v pymarkdown &> /dev/null; then
  pymarkdown \
    --set "extensions.front-matter.enabled=\$!True" \
    --disable-rules MD013,MD024,MD033,MD036,MD041,MD060 \
    scan docs/*.md docs/**/*.md
  echo "Markdown lint PASSED"
else
  echo "SKIP: pymarkdown not installed (pip install pymarkdownlnt)"
fi

echo "=== Platform Interface Gate: $PKG ==="

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

# Exclude test-infrastructure files from coverage
lcov --remove coverage/lcov.info '*/mock_monty_platform.dart' \
  --output-file coverage/lcov.info --quiet 2>/dev/null || true

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

echo "=== Platform Interface Gate PASSED (${PCT}% coverage) ==="
