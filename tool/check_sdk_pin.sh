#!/usr/bin/env bash
# =============================================================================
# One Dart SDK everywhere: every workflow pin, and the SDK running this check
# =============================================================================
# `dart format` output depends on the SDK that runs it: dart_style ships style
# fixes that are NOT language-versioned, even in SDK patch releases. A file
# formatted locally with one SDK can fail CI's format check under another
# ("format wars"). So every `setup-dart` pin in .github/workflows must name the
# same exact version, and the `dart` on PATH must be that version too.
#
# In CI the second half holds by construction (setup-dart installed the pin).
# Locally it is the check that tells you to switch SDKs BEFORE you format.
#
# Usage: bash tool/check_sdk_pin.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

PINS=$(grep -hE '^[[:space:]]*sdk:[[:space:]]*[0-9]' .github/workflows/*.y*ml \
  | sed -E 's/^[[:space:]]*sdk:[[:space:]]*([^[:space:]#]+).*/\1/' | sort -u)
N=$(printf '%s\n' "$PINS" | grep -c . || true)
if [ "$N" -eq 0 ]; then
  echo "FAIL: no exact setup-dart 'sdk:' pins found in .github/workflows."
  exit 1
fi
if [ "$N" -ne 1 ]; then
  echo "FAIL: workflows pin different Dart SDKs:"
  grep -nE '^[[:space:]]*sdk:[[:space:]]*[0-9]' .github/workflows/*.y*ml | sed 's/^/    /'
  exit 1
fi
PIN=$PINS

LOCAL=$(dart --version 2>&1 | sed -nE 's/^Dart SDK version: ([^ ]+).*/\1/p')
if [ "$LOCAL" != "$PIN" ]; then
  echo "FAIL: dart on PATH is ${LOCAL:-unknown}; CI pins $PIN."
  echo "  dart format output differs between SDK releases, so formatting with"
  echo "  this SDK can fail CI's format check. Switch to $PIN before formatting."
  exit 1
fi

echo "PASS — workflows and local dart all on $PIN"
