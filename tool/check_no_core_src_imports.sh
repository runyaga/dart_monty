#!/usr/bin/env bash
# =============================================================================
# Nothing under lib/ or test/ may import dart_monty_core's src/
# =============================================================================
# `package:dart_monty_core/src/...` is core's private implementation. Importing
# it couples this package to file paths core is free to move, and it is how
# lib/dart_monty_testing.dart came to re-export core's mock straight out of
# src/ (core#165). Core now ships public entries for everything this package
# needs: dart_monty_core.dart and dart_monty_core_testing.dart.
#
# GREP'S EXIT STATUS IS THREE-VALUED, AND ONLY ONE OF THE THREE IS A PASS.
#   0 = a match           -> FAIL (an import of src/ exists)
#   1 = no match          -> PASS
#   2 = the scan errored  -> FAIL (a missing directory or unreadable file
#                                  checked nothing, and must not read as clean)
# `! grep ...` would treat 2 as a pass, which is why this does not use it.
#
# Usage: bash tool/check_no_core_src_imports.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

PATTERN='package:dart_monty_core/src/'

grep -rnE "$PATTERN" lib test
rc=$?

case "$rc" in
  1)
    echo "PASS — no import of $PATTERN under lib/ or test/"
    exit 0
    ;;
  0)
    echo ""
    echo "FAIL: the lines above import dart_monty_core's private src/."
    echo "  Use package:dart_monty_core/dart_monty_core.dart, or"
    echo "  package:dart_monty_core/dart_monty_core_testing.dart for the mock."
    echo "  If core has no public entry for what you need, that is a core"
    echo "  issue to file, not an import to add here."
    exit 1
    ;;
  *)
    echo "FAIL: grep exited $rc — the scan itself failed, so nothing was checked."
    exit 1
    ;;
esac
