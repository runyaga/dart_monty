#!/usr/bin/env bash
# =============================================================================
# Test: WASM Cancel Benchmark bridge.js getDefaultSessionId API
#
# Validates that bridge.js exposes getDefaultSessionId() which returns
# the internal defaultSessionId closure variable. This is used by the
# WASM cancel benchmark to get the session ID for disposeSession().
#
# Usage: bash tool/test_wasm_benchmark_patch.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BRIDGE="$ROOT/assets/dart_monty_bridge.js"
BRIDGE_SRC="$ROOT/js/src/bridge.js"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    ((PASS++))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" file="$3"
  if grep -q "$needle" "$file"; then
    echo "  PASS: $desc"
    ((PASS++))
  else
    echo "  FAIL: $desc (not found: $needle)"
    ((FAIL++))
  fi
}

# Node.js helper: stubs browser globals, loads bridge.js, runs expression
node_eval() {
  node -e "
    const _origLog = console.log;
    global.window = global;
    global.document = undefined;
    global.location = { href: 'http://localhost/' };
    global.Worker = class Worker { constructor() { throw new Error('no worker'); } };
    global.URL = class URL { constructor(a,b) { this.href = a; } };
    console.log = () => {};
    require('$BRIDGE');
    console.log = _origLog;
    $1
  " 2>/dev/null || echo "error"
}

echo "=== Test: bridge.js getDefaultSessionId API ==="

# --- T1: Source and built bridge.js exist ---
echo ""
echo "T1: Bridge files exist"
if [ -f "$BRIDGE" ]; then echo "  PASS: built bridge.js"; ((PASS++)); else echo "  FAIL: built bridge.js missing"; ((FAIL++)); fi
if [ -f "$BRIDGE_SRC" ]; then echo "  PASS: source bridge.js"; ((PASS++)); else echo "  FAIL: source bridge.js missing"; ((FAIL++)); fi

# --- T2: Source has getDefaultSessionId ---
echo ""
echo "T2: Source bridge.js has getDefaultSessionId"
assert_contains "source exports getDefaultSessionId" "getDefaultSessionId" "$BRIDGE_SRC"

# --- T3: Built bridge.js has getDefaultSessionId ---
echo ""
echo "T3: Built bridge.js has getDefaultSessionId"
assert_contains "built asset has getDefaultSessionId" "getDefaultSessionId" "$BRIDGE"

# --- T4: Built bridge.js is valid JavaScript ---
echo ""
echo "T4: Built bridge.js is syntactically valid"
if command -v node &>/dev/null; then
  if node --check "$BRIDGE" 2>/dev/null; then
    echo "  PASS: node --check passes"
    ((PASS++))
  else
    echo "  FAIL: node --check failed"
    ((FAIL++))
  fi
else
  echo "  SKIP: node not available"
fi

# --- T5: getDefaultSessionId is a function on DartMontyBridge ---
echo ""
echo "T5: getDefaultSessionId is callable"
if command -v node &>/dev/null; then
  RESULT=$(node_eval "console.log(typeof window.DartMontyBridge.getDefaultSessionId);")
  assert_eq "getDefaultSessionId is a function" "function" "$RESULT"

  RESULT2=$(node_eval "console.log(window.DartMontyBridge.getDefaultSessionId());")
  assert_eq "returns null before init" "null" "$RESULT2"
else
  echo "  SKIP: node not available"
fi

# --- T6: DartMontyBridge exports all expected properties ---
echo ""
echo "T6: DartMontyBridge has all expected exports"
if command -v node &>/dev/null; then
  KEYS=$(node_eval "console.log(Object.keys(window.DartMontyBridge).sort().join(','));")
  for prop in init run start createSession disposeSession getDefaultSessionId; do
    if echo "$KEYS" | grep -q "$prop"; then
      echo "  PASS: DartMontyBridge.$prop exists"
      ((PASS++))
    else
      echo "  FAIL: DartMontyBridge.$prop missing (keys: $KEYS)"
      ((FAIL++))
    fi
  done
else
  echo "  SKIP: node not available"
fi

# --- T7: Benchmark HTML references _benchFastCancel ---
echo ""
echo "T7: Benchmark HTML has _benchFastCancel helper"
HTML="$ROOT/test/wasm/integration/web/cancel_benchmark.html"
if [ -f "$HTML" ]; then
  assert_contains "HTML has _benchFastCancel" "_benchFastCancel" "$HTML"
  assert_contains "HTML calls disposeSession" "disposeSession" "$HTML"
else
  echo "  SKIP: cancel_benchmark.html not found"
fi

# --- T8: Benchmark Dart uses getDefaultSessionId ---
echo ""
echo "T8: Benchmark Dart uses getDefaultSessionId"
DART="$ROOT/test/wasm/integration/cancel_benchmark.dart"
if [ -f "$DART" ]; then
  assert_contains "Dart declares getDefaultSessionId interop" "getDefaultSessionId" "$DART"
  assert_contains "Dart calls _getDefaultSessionId()" "_getDefaultSessionId()" "$DART"
else
  echo "  SKIP: cancel_benchmark.dart not found"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
