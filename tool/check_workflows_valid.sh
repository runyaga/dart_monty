#!/usr/bin/env bash
# =============================================================================
# The workflow files must be VALID, or CI silently stops running.
# =============================================================================
# A workflow GitHub cannot parse does not fail loudly. It records a run with
# ZERO JOBS and conclusion "failure", and — the part that actually hurts — it
# stops matching its own triggers, so the pull_request runs simply cease.
#
# Measured 2026-09-14: a duplicate `env:` key in one step (ci.yaml, added by a
# commit that only meant to pass one more variable) took CI out for THIRTEEN
# COMMITS. Every push produced a 0-job failure, the PR runs stopped entirely,
# and `python3 -c 'import yaml; yaml.safe_load(...)'` passed the whole time —
# PyYAML keeps the last duplicate key, GitHub rejects the document.
#
# So YAML-parses is not the check. This is.
#
# actionlint is fetched on demand and cached; if it cannot be fetched the gate
# SKIPS with a warning rather than failing, because a network hiccup must not
# block a commit — but it says so, so a silent skip is impossible to mistake
# for a pass.
#
# Usage: bash tool/check_workflows_valid.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

VERSION=1.7.7
CACHE="${HOME}/.cache/actionlint-${VERSION}"

if [ ! -x "$CACHE" ]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "SKIP: no actionlint build for $(uname -m) — workflows NOT validated"; exit 0 ;;
  esac
  URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}_$(uname -s | tr '[:upper:]' '[:lower:]')_${ARCH}.tar.gz"
  mkdir -p "$(dirname "$CACHE")"
  TMP="$(mktemp -d)"
  if curl -sfL --max-time 60 "$URL" -o "$TMP/al.tgz" 2>/dev/null \
     && tar xzf "$TMP/al.tgz" -C "$TMP" actionlint 2>/dev/null; then
    mv "$TMP/actionlint" "$CACHE"
    chmod +x "$CACHE"
  else
    rm -rf "$TMP"
    echo "SKIP: could not fetch actionlint — workflows NOT validated this run."
    echo "      This is a SKIP, not a pass. Re-run with network to check them."
    exit 77
  fi
  rm -rf "$TMP"
fi

# -shellcheck= disables the embedded shellcheck: the run blocks here are already
# covered by the gate's own discipline, and a shellcheck opinion is not a reason
# to block a commit. Workflow VALIDITY is.
if ! "$CACHE" -shellcheck= -pyflakes= .github/workflows/*.yaml .github/workflows/*.yml 2>&1; then
  echo ""
  echo "  A workflow GitHub cannot parse does not fail loudly: it records a"
  echo "  0-job run and STOPS MATCHING ITS TRIGGERS, so PR checks quietly stop"
  echo "  running. Fix the file above before committing."
  exit 1
fi

N=$(ls .github/workflows/*.yaml .github/workflows/*.yml 2>/dev/null | wc -l | tr -d ' ')
echo "PASS — all $N workflow files are valid."
