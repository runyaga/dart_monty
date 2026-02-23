#!/usr/bin/env bash
set -euo pipefail

# Publish all dart_monty packages to pub.dev in dependency order.
#
# This script:
# 1. Verifies a clean git working tree
# 2. Reads the version from root pubspec.yaml
# 3. Swaps path deps to version constraints and removes publish_to: 'none'
# 4. Runs dart pub publish --dry-run on all packages
# 5. Publishes each package with --force
# 6. Restores all pubspec.yaml files to their original state
#
# Usage:
#   bash tool/publish.sh              # dry-run only
#   bash tool/publish.sh --publish    # actually publish

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DRY_RUN=true

if [[ "${1:-}" == "--publish" ]]; then
  DRY_RUN=false
fi

# Publish order (leaf-first)
PACKAGES=(
  "packages/dart_monty_platform_interface"
  "packages/dart_monty_ffi"
  "packages/dart_monty_wasm"
  "packages/dart_monty_web"
  "packages/dart_monty_desktop"
  "."
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Portable sed -i (GNU vs BSD)
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

restore() {
  echo ""
  echo "==> Restoring pubspec.yaml files..."
  cd "$ROOT_DIR"
  git restore '**/pubspec.yaml' pubspec.yaml 2>/dev/null || true
  echo "    Done."
}

trap restore EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

cd "$ROOT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "ERROR: Working tree is not clean. Commit or stash changes first."
  exit 1
fi

# Read version from root pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | head -1 | awk '{print $2}')
echo "==> Publishing dart_monty v${VERSION}"
echo ""

# ---------------------------------------------------------------------------
# Swap path deps to version constraints
# ---------------------------------------------------------------------------

echo "==> Swapping path deps to ^${VERSION}..."

for pubspec in pubspec.yaml packages/*/pubspec.yaml; do
  # Replace path deps with version constraints
  # Matches patterns like:
  #   dart_monty_platform_interface:
  #     path: ../dart_monty_platform_interface
  # And replaces with:
  #   dart_monty_platform_interface: ^0.1.0+1
  sedi -E '/^  (dart_monty[a-z_]*):/,/^    path:/{
    /^    path:/d
  }' "$pubspec"

  # Now fix the remaining "dart_monty_*:\n" (no value) to "dart_monty_*: ^VERSION"
  sedi -E "s/^  (dart_monty[a-z_]*):\$/  \1: ^${VERSION}/" "$pubspec"
done

echo "    Done."
echo ""

# ---------------------------------------------------------------------------
# Dry-run all packages
# ---------------------------------------------------------------------------

echo "==> Running dry-run for all packages..."
echo ""

for pkg in "${PACKAGES[@]}"; do
  pkg_dir="$ROOT_DIR/$pkg"
  pkg_name=$(grep '^name:' "$pkg_dir/pubspec.yaml" | awk '{print $2}')
  echo "--- $pkg_name ---"
  cd "$pkg_dir"
  # Exit code 1  = version solving failed (sibling packages not yet on pub.dev).
  # Exit code 65 = warnings only (expected: pubspecs modified by path-dep swap).
  # Exit code 69 = dep resolution failure (expected for unpublished sibling packages).
  rc=0
  dart pub publish --dry-run || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && [ "$rc" -ne 65 ] && [ "$rc" -ne 69 ]; then
    echo "ERROR: dart pub publish --dry-run failed with exit code $rc"
    exit "$rc"
  fi
  if [ "$rc" -eq 1 ] || [ "$rc" -eq 69 ]; then
    echo "WARN: dep resolution failed (sibling packages not yet on pub.dev)"
  fi
  echo ""
done

if $DRY_RUN; then
  echo "==> Dry-run complete. Run with --publish to publish for real."
  exit 0
fi

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

echo "==> Publishing all packages..."
echo ""

for pkg in "${PACKAGES[@]}"; do
  pkg_dir="$ROOT_DIR/$pkg"
  pkg_name=$(grep '^name:' "$pkg_dir/pubspec.yaml" | awk '{print $2}')
  echo "--- Publishing $pkg_name ---"
  cd "$pkg_dir"
  dart pub publish --force
  echo ""
  echo "    Waiting 15s for pub.dev indexing..."
  sleep 15
done

echo "==> All packages published successfully!"
