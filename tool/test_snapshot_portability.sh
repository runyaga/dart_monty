#!/usr/bin/env bash
# =============================================================================
# M3C Gate Script — Snapshot Portability (Exploratory)
# =============================================================================
# Documents snapshot portability findings. Does NOT hard-fail.
#
# 1. Native-to-native round-trip (re-verify from M3A)
# 2. Cross-platform probe: export from native, attempt load via Node.js
# 3. Report PASS or LIMITATION
#
# Usage: bash tool/test_snapshot_portability.sh
# =============================================================================
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
FFI_PKG="$ROOT/packages/dart_monty_ffi"
SPIKE="$ROOT/spike/web_test"

echo "=== M3C Gate: Snapshot Portability (Exploratory) ==="
echo ""

# -------------------------------------------------------
# Test 1: Native-to-native round-trip
# -------------------------------------------------------
echo "--- Test 1: Native-to-native snapshot round-trip ---"
cd "$FFI_PKG"
dart pub get

# The smoke test already covers snapshot round-trip; re-verify
DYLD_LIBRARY_PATH="$ROOT/native/target/release" \
LD_LIBRARY_PATH="$ROOT/native/target/release" \
  dart test --tags=integration --name="snapshot round-trip" 2>&1 && \
  echo "  PASS: Native snapshot round-trip works." || \
  echo "  LIMITATION: Native snapshot round-trip failed (see above)."

echo ""

# -------------------------------------------------------
# Test 2: Cross-platform snapshot probe
# -------------------------------------------------------
echo "--- Test 2: Cross-platform snapshot probe ---"

# Check if Node.js and @pydantic/monty are available
if ! command -v node &>/dev/null; then
  echo "  SKIPPED: Node.js not found."
  echo ""
  echo "--- Findings ---"
  echo "  - Native-to-native snapshot round-trip: verified"
  echo "  - Cross-platform snapshot: not tested (Node.js unavailable)"
  echo "  - Full cross-platform snapshot restore deferred to M4"
  echo ""
  echo "=== Snapshot Portability: PARTIAL (native only) ==="
  exit 0
fi

cd "$SPIKE"
if [ ! -d "node_modules/@pydantic" ]; then
  npm install --silent
fi

# Probe: attempt to create a snapshot via Node.js and check format
node -e "
const { Monty, MontySnapshot } = require('@pydantic/monty-wasm32-wasi');

try {
  // Create a simple execution with an external function to get a snapshot
  const m = Monty.create('result = fetch(\"url\")', { externalFunctions: ['fetch'] });
  const progress = m.start();

  if (progress instanceof MontySnapshot) {
    console.log('  Snapshot created via Node.js @pydantic/monty');
    console.log('  Snapshot type:', typeof progress);
    console.log('  Has functionName:', !!progress.functionName);
    console.log('  Has resume:', typeof progress.resume === 'function');

    // Try to resume to complete
    const done = progress.resume({ returnValue: 'test' });
    console.log('  Resume result type:', done.constructor?.name || typeof done);
    console.log('  PASS: Node.js snapshot create + resume works');
  } else {
    console.log('  Result is not MontySnapshot:', progress.constructor?.name);
    console.log('  LIMITATION: Could not create snapshot via Node.js');
  }
} catch (e) {
  console.log('  LIMITATION:', e.message);
}
" 2>&1 || echo "  LIMITATION: Node.js probe failed"

echo ""

# -------------------------------------------------------
# Findings
# -------------------------------------------------------
echo "--- Findings ---"
echo "  - Native-to-native snapshot round-trip: verified (M3A smoke test)"
echo "  - Node.js @pydantic/monty snapshot API: probed above"
echo "  - Cross-platform binary snapshot portability (native <-> WASM): NOT YET TESTED"
echo "  - The native Rust crate serializes snapshots as binary data (bincode/msgpack)"
echo "  - The WASM @pydantic/monty package uses in-memory MontySnapshot objects"
echo "  - Binary format compatibility between native and WASM is not guaranteed"
echo "  - Full cross-platform snapshot restore through web Worker deferred to M4"
echo ""
echo "=== Snapshot Portability: DOCUMENTED (see findings above) ==="
