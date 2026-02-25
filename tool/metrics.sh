#!/usr/bin/env bash
# =============================================================================
# Metrics Capture — dart_monty
# =============================================================================
# Captures a machine-readable JSON snapshot of project health metrics.
# Output goes to stdout (pipe to file for baseline).
#
# Usage: bash tool/metrics.sh
#        bash tool/metrics.sh > ci-review/baseline.json
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Helper: count lines in lib/ and test/ for a package
count_lines() {
  local pkg="$1"
  local dir="$2"
  local path="$ROOT/packages/$pkg/$dir"
  if [ -d "$path" ]; then
    find "$path" -name '*.dart' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

# Helper: count test files for a package
count_tests() {
  local pkg="$1"
  local pkg_path="$ROOT/packages/$pkg"
  if [ -d "$pkg_path/test" ]; then
    # Count test() and group() calls as a proxy for test count
    find "$pkg_path/test" -name '*_test.dart' -type f -exec grep -c "test(" {} + 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  else
    echo "0"
  fi
}

# Helper: get coverage for a Dart package (if lcov.info exists)
get_coverage() {
  local pkg="$1"
  local lcov="$ROOT/packages/$pkg/coverage/lcov.info"
  if [ -f "$lcov" ]; then
    local total hit pct
    total=$(grep -c '^DA:' "$lcov" 2>/dev/null || echo "0")
    hit=$(grep '^DA:' "$lcov" 2>/dev/null | grep -cv ',0$' || echo "0")
    if [ "$total" -gt 0 ]; then
      pct=$(( hit * 100 / total ))
      echo "$pct"
    else
      echo "null"
    fi
  else
    echo "null"
  fi
}

# Collect Dart package metrics
DART_PACKAGES=(
  dart_monty_platform_interface
  dart_monty_ffi
  dart_monty_wasm
  dart_monty_web
  dart_monty_desktop
)

# Start JSON output
echo "{"
echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
echo "  \"git_sha\": \"$(git rev-parse --short HEAD)\","
echo "  \"git_branch\": \"$(git rev-parse --abbrev-ref HEAD)\","

# Dart packages
echo "  \"packages\": {"
for i in "${!DART_PACKAGES[@]}"; do
  pkg="${DART_PACKAGES[$i]}"
  src_lines=$(count_lines "$pkg" "lib")
  test_lines=$(count_lines "$pkg" "test")
  test_count=$(count_tests "$pkg")
  coverage=$(get_coverage "$pkg")

  echo "    \"$pkg\": {"
  echo "      \"source_lines\": $src_lines,"
  echo "      \"test_lines\": $test_lines,"
  echo "      \"test_count\": $test_count,"
  if [ "$coverage" == "null" ]; then
    echo "      \"coverage_pct\": null"
  else
    echo "      \"coverage_pct\": $coverage"
  fi
  if [ $i -lt $(( ${#DART_PACKAGES[@]} - 1 )) ]; then
    echo "    },"
  else
    echo "    }"
  fi
done
echo "  },"

# Totals
total_src=0
total_test=0
total_tests=0
for pkg in "${DART_PACKAGES[@]}"; do
  s=$(count_lines "$pkg" "lib")
  t=$(count_lines "$pkg" "test")
  tc=$(count_tests "$pkg")
  total_src=$((total_src + s))
  total_test=$((total_test + t))
  total_tests=$((total_tests + tc))
done

echo "  \"totals\": {"
echo "    \"dart_source_lines\": $total_src,"
echo "    \"dart_test_lines\": $total_test,"
echo "    \"dart_test_count\": $total_tests,"
echo "    \"test_to_source_ratio\": \"$(echo "scale=1; $total_test * 10 / $total_src / 10" | bc 2>/dev/null || echo "N/A")\""
echo "  },"

# Rust crate
echo "  \"rust\": {"
if [ -d "$ROOT/native/src" ]; then
  rust_src=$(find "$ROOT/native/src" -name '*.rs' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  rust_test=$(find "$ROOT/native/tests" -name '*.rs' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' ')
  echo "    \"source_lines\": $rust_src,"
  echo "    \"test_lines\": $rust_test,"

  if command -v cargo &>/dev/null; then
    rust_test_count=$(cd "$ROOT/native" && cargo test -- --list 2>/dev/null | grep -c '^\S.*: test$' || echo "0")
    echo "    \"test_count\": $rust_test_count,"

    if cd "$ROOT/native" && cargo clippy -- -D warnings >/dev/null 2>&1; then
      echo "    \"clippy\": \"pass\""
    else
      echo "    \"clippy\": \"fail\""
    fi
  else
    echo "    \"test_count\": null,"
    echo "    \"clippy\": null"
  fi
else
  echo "    \"source_lines\": 0,"
  echo "    \"test_lines\": 0,"
  echo "    \"test_count\": null,"
  echo "    \"clippy\": null"
fi
echo "  }"

echo "}"
