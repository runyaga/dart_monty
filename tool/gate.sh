#!/usr/bin/env bash
# =============================================================================
# Unified Quality Gate — dart_monty (single-package)
# =============================================================================
# Single script that runs EVERY quality check. Must pass before any PR merges.
# Gracefully skips checks when toolchains are missing (cargo, Chrome, dcm)
# but Dart gates always run.
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
# 1. Dart Format
# -------------------------------------------------------
run_check "dart format" dart format --set-exit-if-changed .

# -------------------------------------------------------
# 2. Dart Analyze
# -------------------------------------------------------
run_check "dart analyze" dart analyze --fatal-infos

# -------------------------------------------------------
# 3. Dart Doc Validate Links
# -------------------------------------------------------
run_check "dart doc --validate-links" dart doc --validate-links .

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
# 6. DCM (Dart Code Metrics) — requires dcm installed
# -------------------------------------------------------
# Helper: advisory check (reports but does not fail gate)
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
  # Blocking: 98 lint rules, must be zero issues
  run_check "dcm analyze" dcm analyze lib
  # Advisory: report but don't fail gate (known false positives / pre-existing)
  run_advisory "dcm calculate-metrics" dcm calculate-metrics lib
  run_advisory "dcm check-unused-code" dcm check-unused-code lib
  run_advisory "dcm check-unused-files" dcm check-unused-files lib
  run_advisory "dcm check-dependencies" dcm check-dependencies .
  run_advisory "dcm check-parameters" dcm check-parameters lib

  # Upload to DCM dashboard (main branch only, requires DCM_PROJECT_KEY)
  if [[ "${DCM_PROJECT_KEY:-}" != "" ]]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_BRANCH" == "main" ]]; then
      echo ""
      echo "========================================"
      echo "  DCM dashboard upload"
      echo "========================================"
      dcm run lib \
        --all \
        --upload \
        --project="$DCM_PROJECT_KEY" \
        --email="${DCM_EMAIL:-}" \
        --ci-key="${DCM_CI_KEY:-}" \
        && echo "  -> UPLOADED" \
        || echo "  -> UPLOAD FAILED (non-blocking)"
    else
      echo ""
      echo "  DCM dashboard: skipped (not on main, branch=$CURRENT_BRANCH)"
    fi
  fi
else
  skip_check "dcm" "dcm not installed (commercial license required)"
fi

# -------------------------------------------------------
# 7. Dart Tests (unit)
# -------------------------------------------------------
run_check "dart test" dart test

# -------------------------------------------------------
# 8. Rust Gate — skip if no cargo
# -------------------------------------------------------
if [[ "$DART_ONLY" == true ]]; then
  skip_check "Rust gate" "--dart-only flag"
elif command -v cargo &>/dev/null; then
  run_check "Rust gate" bash tool/test_rust.sh
else
  skip_check "Rust gate" "cargo not installed"
fi

# -------------------------------------------------------
# 9. Python Ladder Parity — skip if --dart-only
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
