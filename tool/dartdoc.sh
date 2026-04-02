#!/usr/bin/env bash
# Generate dartdoc for all published packages.
#
# Usage:
#   bash tool/dartdoc.sh              # All packages
#   bash tool/dartdoc.sh dart_monty   # Single package
#
# Output goes to packages/<name>/doc/ (or doc/ for root).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Packages to document (published to pub.dev).
PACKAGES=(
  "."
  "packages/dart_monty_platform_interface"
  "packages/dart_monty_bridge"
  "packages/dart_monty_ffi"
  "packages/dart_monty_wasm"
)

generate() {
  local pkg_dir="$1"
  local abs_dir="$REPO_ROOT/$pkg_dir"
  local name
  name=$(grep '^name:' "$abs_dir/pubspec.yaml" | head -1 | awk '{print $2}')

  echo "=== Generating docs for $name ==="
  (cd "$abs_dir" && dart doc --validate-links .)
  echo ""
}

if [[ $# -gt 0 ]]; then
  # Single package by name
  target="$1"
  for pkg in "${PACKAGES[@]}"; do
    abs="$REPO_ROOT/$pkg"
    name=$(grep '^name:' "$abs/pubspec.yaml" | head -1 | awk '{print $2}')
    if [[ "$name" == "$target" ]]; then
      generate "$pkg"
      exit 0
    fi
  done
  echo "Unknown package: $target"
  exit 1
else
  for pkg in "${PACKAGES[@]}"; do
    generate "$pkg"
  done
fi

echo "Done. Open doc/api/index.html in any package to browse."
