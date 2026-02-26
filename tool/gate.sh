#!/usr/bin/env bash
# =============================================================================
# Unified Quality Gate — dart_monty
# =============================================================================
# Single script that runs EVERY quality check. Must pass before any slice PR
# merges. Gracefully skips checks when toolchains are missing (cargo, Chrome,
# dcm) but Dart gates always run.
#
# Usage: bash tool/gate.sh
#        bash tool/gate.sh --dart-only    # Skip Rust, WASM, web integration
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

DART_ONLY=false
if [[ "${1:-}" == "--dart-only" ]]; then
  DART_ONLY=true
fi

FAILED=()
SKIPPED=()

# Helper: run a check, track failures
run_check() {
  local name="$1"
  shift
  echo ""
  echo "========================================"
  echo "  $name"
  echo "========================================"
  if "$@"; then
    echo "  -> PASSED"
  else
    echo "  -> FAILED"
    FAILED+=("$name")
  fi
}

# Helper: skip a check
skip_check() {
  local name="$1"
  local reason="$2"
  echo ""
  echo "========================================"
  echo "  $name — SKIPPED ($reason)"
  echo "========================================"
  SKIPPED+=("$name")
}

# -------------------------------------------------------
# 1. Dart Format (all packages)
# -------------------------------------------------------
run_check "dart format" dart format --set-exit-if-changed .

# -------------------------------------------------------
# 2. Dart Analyze (all packages via analyze_packages.py)
# -------------------------------------------------------
run_check "dart analyze (all packages)" python3 tool/analyze_packages.py

# -------------------------------------------------------
# 3. Dart Doc Validate Links (per sub-package)
# -------------------------------------------------------
check_dart_doc() {
  local exit_code=0
  for pkg in packages/*/; do
    local name
    name=$(basename "$pkg")
    local pubspec="$pkg/pubspec.yaml"
    [ -f "$pubspec" ] || continue

    echo "  --- dart doc: $name ---"
    if grep -q 'sdk: flutter' "$pubspec"; then
      # Flutter packages need flutter pub get first
      (cd "$pkg" && flutter pub get --suppress-analytics >/dev/null 2>&1 && dart doc --validate-links .) || {
        echo "  dart doc FAILED for $name"
        exit_code=1
      }
    else
      (cd "$pkg" && dart pub get >/dev/null 2>&1 && dart doc --validate-links .) || {
        echo "  dart doc FAILED for $name"
        exit_code=1
      }
    fi
  done
  return $exit_code
}
run_check "dart doc --validate-links" check_dart_doc

# -------------------------------------------------------
# 4. Pymarkdown (all markdown files)
# -------------------------------------------------------
if command -v pymarkdown &>/dev/null; then
  run_check "pymarkdown scan" pymarkdown \
    --set "extensions.front-matter.enabled=\$!True" \
    --disable-rules MD013,MD024,MD033,MD036,MD041,MD060 \
    scan docs/*.md
else
  skip_check "pymarkdown scan" "pymarkdown not installed (pip install pymarkdownlnt)"
fi

# -------------------------------------------------------
# 5. Gitleaks (secret detection)
# -------------------------------------------------------
if command -v gitleaks &>/dev/null; then
  run_check "gitleaks detect" gitleaks detect --no-banner
else
  skip_check "gitleaks detect" "gitleaks not installed"
fi

# -------------------------------------------------------
# 6. DCM (Dart Code Metrics) — advisory, does not fail gate
# -------------------------------------------------------
# DCM has ~115 pre-existing issues that will be fixed incrementally
# across slices 1-8. Once the baseline reaches zero, switch run_advisory
# to run_check to make DCM blocking.
run_advisory() {
  local name="$1"
  shift
  echo ""
  echo "========================================"
  echo "  $name (advisory)"
  echo "========================================"
  if "$@"; then
    echo "  -> CLEAN"
  else
    echo "  -> ISSUES FOUND (advisory — not blocking gate)"
  fi
}

if command -v dcm &>/dev/null; then
  run_advisory "dcm analyze" dcm analyze packages
  run_advisory "dcm check-unused-code" dcm check-unused-code packages
  run_advisory "dcm check-unused-files" dcm check-unused-files packages
  run_advisory "dcm check-dependencies" dcm check-dependencies packages
else
  skip_check "dcm" "dcm not installed (commercial license required)"
fi

# -------------------------------------------------------
# 7. Dart Tests: platform_interface
# -------------------------------------------------------
run_check "test: platform_interface" bash tool/test_platform_interface.sh

# -------------------------------------------------------
# 8. Dart Tests: dart_monty_ffi
# -------------------------------------------------------
run_check "test: dart_monty_ffi" bash tool/test_ffi.sh

# -------------------------------------------------------
# 9. Rust Gate — skip if no cargo
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "Rust gate" "--dart-only flag"
elif command -v cargo &>/dev/null; then
  run_check "Rust gate" bash tool/test_rust.sh
else
  skip_check "Rust gate" "cargo not installed"
fi

# -------------------------------------------------------
# 10. Native plugin tests (M5) — skip if no flutter
# -------------------------------------------------------
if command -v flutter &>/dev/null; then
  run_check "test: dart_monty_native" bash tool/test_native.sh
else
  skip_check "test: dart_monty_native" "flutter not installed"
fi

# -------------------------------------------------------
# 11. WASM package tests (M4) — skip if --dart-only
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "test: dart_monty_wasm" "--dart-only flag"
else
  run_check "test: dart_monty_wasm" bash tool/test_wasm.sh
fi

# -------------------------------------------------------
# 12. Web plugin tests (M6)
# -------------------------------------------------------
if command -v flutter &>/dev/null; then
  run_check "test: dart_monty_web" bash tool/test_web.sh
else
  skip_check "test: dart_monty_web" "flutter not installed"
fi

# -------------------------------------------------------
# 13. Python Ladder Parity (M3C) — skip if --dart-only
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "Python ladder parity" "--dart-only flag"
else
  run_check "Python ladder parity" bash tool/test_python_ladder.sh
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================"
echo "  GATE SUMMARY"
echo "========================================"

if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo ""
  echo "  Skipped (${#SKIPPED[@]}):"
  for s in "${SKIPPED[@]}"; do
    echo "    - $s"
  done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo "  FAILED (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do
    echo "    - $f"
  done
  echo ""
  echo "  GATE: FAILED"
  exit 1
fi

echo ""
echo "  GATE: PASSED (${#SKIPPED[@]} skipped)"
exit 0
