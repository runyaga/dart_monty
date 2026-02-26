#!/usr/bin/env bash
set -euo pipefail

# Stamp all CHANGELOG.md files for a release.
#
# Replaces `## Unreleased` with `## VERSION` and prepends a fresh
# `## Unreleased` section for future work.
#
# Usage:
#   bash tool/stamp_changelogs.sh 0.2.0

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <version>"
  exit 1
fi

VERSION="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DIRS=(
  "."
  "packages/dart_monty_platform_interface"
  "packages/dart_monty_ffi"
  "packages/dart_monty_wasm"
  "packages/dart_monty_web"
  "packages/dart_monty_native"
)

for dir in "${DIRS[@]}"; do
  file="${ROOT_DIR}/${dir}/CHANGELOG.md"
  if [[ ! -f "$file" ]]; then
    echo "WARNING: $file not found, skipping"
    continue
  fi

  if ! grep -q "^## Unreleased" "$file"; then
    echo "ERROR: $file has no '## Unreleased' section"
    exit 1
  fi

  # Replace `## Unreleased` with `## Unreleased\n\n## VERSION`
  # Uses python3 for portable multi-line replacement (works on macOS + Linux)
  python3 -c "
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('## Unreleased', '## Unreleased\n\n## ${VERSION}', 1))
" "$file"
  echo "Stamped ${dir}/CHANGELOG.md with ${VERSION}"
done

echo ""
echo "Done. Review changes, then commit."
