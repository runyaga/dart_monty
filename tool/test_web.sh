#!/usr/bin/env bash
# =============================================================================
# M6 Gate Script — Web Plugin Package
# =============================================================================
# Validates: pub get, format, analyze, flutter test (Chrome).
#
# Note: Coverage is not available for Chrome-platform tests in Flutter.
# The underlying MontyWasm logic has 100% coverage in dart_monty_wasm.
#
# Usage: bash tool/test_web.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
PKG="$ROOT/packages/dart_monty_web"

cd "$ROOT"

echo "=== M6 Gate: dart_monty_web ==="

# -------------------------------------------------------
# Step 1: Flutter pub get
# -------------------------------------------------------
echo ""
echo "--- flutter pub get ---"
cd "$PKG"
flutter pub get

# -------------------------------------------------------
# Step 2: Format
# -------------------------------------------------------
echo ""
echo "--- dart format --set-exit-if-changed . ---"
dart format --set-exit-if-changed .

# -------------------------------------------------------
# Step 3: Analyze
# -------------------------------------------------------
echo ""
echo "--- flutter analyze --no-fatal-warnings --fatal-infos ---"
# --no-fatal-warnings: path dependencies during development trigger
# invalid_dependency warnings (same as all federated plugin packages).
flutter analyze --no-fatal-warnings --fatal-infos

# -------------------------------------------------------
# Step 4: Unit tests (Chrome platform)
# -------------------------------------------------------
echo ""
echo "--- flutter test --platform chrome ---"
flutter test --platform chrome

# -------------------------------------------------------
# Done
# -------------------------------------------------------
echo ""
echo "=== M6 Gate: PASSED ==="
