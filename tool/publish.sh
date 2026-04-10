#!/usr/bin/env bash
set -euo pipefail

# Publish dart_monty to pub.dev.
#
# This script:
# 1. Verifies a clean git working tree
# 2. Reads the version from pubspec.yaml
# 3. Runs dart pub publish --dry-run
# 4. Publishes with --force (if --publish flag given)
#
# Usage:
#   bash tool/publish.sh              # dry-run only
#   bash tool/publish.sh --publish    # actually publish

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=true

if [[ "${1:-}" == "--publish" ]]; then
  DRY_RUN=false
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

cd "$ROOT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: Working tree is not clean. Commit or stash changes first."
  exit 1
fi

# Read version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}')
echo "==> Publishing dart_monty v${VERSION}"
echo ""

# ---------------------------------------------------------------------------
# Dry-run
# ---------------------------------------------------------------------------

echo "==> Running dry-run..."
echo ""

echo "--- dart_monty ---"
dart pub publish --dry-run
echo ""

if $DRY_RUN; then
  echo "==> Dry-run complete. Run with --publish to publish for real."
  exit 0
fi

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

echo "==> Publishing dart_monty..."
echo ""

dart pub publish --force
echo ""

echo "==> dart_monty v${VERSION} published successfully!"
