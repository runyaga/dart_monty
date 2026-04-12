#!/bin/bash
# Checks that NATIVE_LIB_VERSION was bumped when FFI symbols change.
#
# Run from repo root:
#   bash tool/check_native_version.sh
#
# Returns 0 if clean, 1 if FFI symbols changed without a version bump.

set -euo pipefail

BASE="${1:-origin/main}"

# Check if native/src/lib.rs has new/removed #[no_mangle] exports
FFI_CHANGED=$(git diff "$BASE" -- native/src/lib.rs | grep -c "^[+-].*unsafe extern" || true)

# Check if NATIVE_LIB_VERSION was bumped
VERSION_CHANGED=$(git diff "$BASE" -- native/NATIVE_LIB_VERSION | grep -c "^[+-][0-9]" || true)

if [ "$FFI_CHANGED" -gt 0 ] && [ "$VERSION_CHANGED" -eq 0 ]; then
  echo "ERROR: FFI symbols changed in native/src/lib.rs but NATIVE_LIB_VERSION was not bumped."
  echo "  FFI changes detected: $FFI_CHANGED lines"
  echo "  Bump native/NATIVE_LIB_VERSION to trigger binary rebuild."
  exit 1
fi

echo "OK: FFI symbols and NATIVE_LIB_VERSION are in sync."
