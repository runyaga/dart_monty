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

# Helper: count Dart lines in a directory
count_lines() {
  local dir="$1"
  if [ -d "$dir" ]; then
    find "$dir" -name '*.dart' -type f -exec cat {} + 2>/dev/null | wc -l | tr -d ' '
  else
    echo "0"
  fi
}

# Helper: count test() calls in test files
count_tests() {
  local dir="$1"
  if [ -d "$dir" ]; then
    find "$dir" -name '*_test.dart' -type f -exec grep -c "test(" {} + 2>/dev/null \
      | awk -F: '{s+=$NF} END {print s+0}'
  else
    echo "0"
  fi
}

# Helper: get coverage (if lcov.info exists)
get_coverage() {
  local lcov="$ROOT/coverage/lcov.info"
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

# Dart source areas
AREAS=(ffi wasm platform bridge)

# Start JSON output
echo "{"
echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
echo "  \"git_sha\": \"$(git rev-parse --short HEAD)\","
echo "  \"git_branch\": \"$(git rev-parse --abbrev-ref HEAD)\","

# Per-area metrics
echo "  \"areas\": {"
for i in "${!AREAS[@]}"; do
  area="${AREAS[$i]}"
  src_lines=$(count_lines "$ROOT/lib/src/$area")
  test_lines=$(count_lines "$ROOT/test/$area")
  test_count=$(count_tests "$ROOT/test/$area")

  echo "    \"$area\": {"
  echo "      \"source_lines\": $src_lines,"
  echo "      \"test_lines\": $test_lines,"
  echo "      \"test_count\": $test_count"
  if [ $i -lt $(( ${#AREAS[@]} - 1 )) ]; then
    echo "    },"
  else
    echo "    }"
  fi
done
echo "  },"

# Totals
total_src=$(count_lines "$ROOT/lib")
total_test=$(count_lines "$ROOT/test")
total_tests=$(count_tests "$ROOT/test")
coverage=$(get_coverage)

echo "  \"totals\": {"
echo "    \"dart_source_lines\": $total_src,"
echo "    \"dart_test_lines\": $total_test,"
echo "    \"dart_test_count\": $total_tests,"
if [ "$coverage" == "null" ]; then
  echo "    \"coverage_pct\": null,"
else
  echo "    \"coverage_pct\": $coverage,"
fi
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
