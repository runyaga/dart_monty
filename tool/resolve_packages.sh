#!/usr/bin/env bash
# =============================================================================
# Resolve every NESTED package, so analysis sees the whole repository
# =============================================================================
# `dart pub get` at the root resolves the root and `example/`. It does NOT
# resolve `example/web/`, and `dart analyze` at the root analyses it anyway —
# against no package_config. Every `package:` import in the seven web demos is
# then an unresolved URI.
#
# MEASURED 2026-09-16, CI run 35144134742: the `Dart test` job failed with 21
# analyzer errors, all of the shape
#
#     error - example/web/bin/visualizer.dart:12:8 - Target of URI doesn't
#             exist: 'package:web_example/demo_ready.dart'
#
# while `bash tool/gate.sh` was green on a developer machine. The difference was
# not the code: it was that the developer's tree had `example/web` resolved from
# an earlier run and CI's checkout did not. Reproduced on a pristine clone —
# `dart pub get` then `dart analyze` — to be sure it was the tree and not the
# runner. A gate whose result depends on leftover state from a previous run is
# not a gate.
#
# DISCOVERED, NOT ENUMERATED. `git ls-files '*/pubspec.yaml'` finds every nested
# package there is, so adding an eighth one is resolved by the commit that adds
# it. Listing `example` and `example/web` by name is how this hole opened: the
# root `dart pub get` happens to cover one of them, which made the other look
# like it did not need covering.
#
# Usage: bash tool/resolve_packages.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

MANIFESTS=$(git ls-files '*/pubspec.yaml')
if [ -z "$MANIFESTS" ]; then
  echo "FAIL: git ls-files '*/pubspec.yaml' matched nothing."
  echo "  This repository has nested packages; a glob that stopped matching"
  echo "  would leave them unresolved and analysed against nothing."
  exit 1
fi

RC=0
N=0
for manifest in $MANIFESTS; do
  dir=$(dirname "$manifest")
  N=$((N + 1))
  if ( cd "$dir" && dart pub get ) >/dev/null 2>&1; then
    echo "  resolved  $dir"
  else
    echo "FAIL: dart pub get failed in $dir"
    ( cd "$dir" && dart pub get ) 2>&1 | sed 's/^/    /'
    RC=1
  fi
done

[ "$RC" = "0" ] && echo "PASS — $N nested package(s) resolved"
exit $RC
