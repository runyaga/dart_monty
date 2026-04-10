#!/usr/bin/env bash
set -euo pipefail

# Verify dart_monty is live on pub.dev at the expected version.
#
# Retries up to 12 times (2 minutes) to account for pub.dev indexing delay.
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
PKG="dart_monty"

echo "==> Verifying pub.dev version for v${VERSION}..."
echo ""

success=false
for i in $(seq 1 "$MAX_RETRIES"); do
  LATEST=$(curl -s "https://pub.dev/api/packages/${PKG}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['latest']['version'])" 2>/dev/null \
    || echo "NOT_FOUND")

  if [[ "$LATEST" == "$VERSION" ]]; then
    echo "  OK: ${PKG} is at ${VERSION}"
    success=true
    break
  else
    echo "  Waiting: ${PKG} is at ${LATEST} (expected ${VERSION}), retry ${i}/${MAX_RETRIES}..."
    sleep "$RETRY_DELAY"
  fi
done

echo ""
if [[ "$success" == "false" ]]; then
  echo "ERROR: ${PKG} did not reach ${VERSION} on pub.dev"
  exit 1
fi

echo "${PKG} verified at v${VERSION} on pub.dev."
