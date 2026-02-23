#!/usr/bin/env bash
set -euo pipefail

# Verify all dart_monty packages are live on pub.dev at the expected version.
#
# Retries up to 12 times (2 minutes) per package to account for pub.dev
# indexing delay.
#
# Usage:
#   bash tool/verify_publish.sh 0.2.0

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

VERSION="$1"
MAX_RETRIES=12
RETRY_DELAY=10

PACKAGES=(
  "dart_monty_platform_interface"
  "dart_monty_ffi"
  "dart_monty_wasm"
  "dart_monty_web"
  "dart_monty_desktop"
  "dart_monty"
)

echo "==> Verifying pub.dev versions for v${VERSION}..."
echo ""

FAILED=0

for pkg in "${PACKAGES[@]}"; do
  success=false
  for i in $(seq 1 "$MAX_RETRIES"); do
    LATEST=$(curl -s "https://pub.dev/api/packages/${pkg}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['latest']['version'])" 2>/dev/null \
      || echo "NOT_FOUND")

    if [[ "$LATEST" == "$VERSION" ]]; then
      echo "  OK: ${pkg} is at ${VERSION}"
      success=true
      break
    else
      echo "  Waiting: ${pkg} is at ${LATEST} (expected ${VERSION}), retry ${i}/${MAX_RETRIES}..."
      sleep "$RETRY_DELAY"
    fi
  done

  if [[ "$success" == "false" ]]; then
    echo "  FAIL: ${pkg} did not reach ${VERSION} on pub.dev"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
if [[ "$FAILED" -gt 0 ]]; then
  echo "ERROR: ${FAILED} package(s) failed verification."
  exit 1
fi

echo "All ${#PACKAGES[@]} packages verified at v${VERSION} on pub.dev."
