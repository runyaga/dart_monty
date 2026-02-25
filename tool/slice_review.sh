#!/usr/bin/env bash
# =============================================================================
# Slice Review — dart_monty
# =============================================================================
# Runs tests/gate, captures metrics delta, generates unified diff, and
# assembles a lean review prompt. The prompt contains instructions + metrics.
# Changed source files and the diff are passed separately to read_files.
#
# Usage:
#   bash tool/slice_review.sh 1                # full: tests + gate + metrics
#   bash tool/slice_review.sh 1 --skip-tests   # reuse existing lcov data
#   bash tool/slice_review.sh 1 --skip-gate    # skip gate.sh
#   bash tool/slice_review.sh 1 --skip-all     # skip both tests and gate
#   bash tool/slice_review.sh 1 --context path/to/file  # add unchanged context file
#
# Output:
#   ci-review/slice-reviews/slice-N-prompt.md   (review instructions)
#   ci-review/slice-reviews/slice-N.diff        (unified diff)
# =============================================================================
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# -------------------------------------------------------
# Argument parsing
# -------------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: bash tool/slice_review.sh <slice-number> [--skip-tests|--skip-gate|--skip-all] [--context <file>]..."
  exit 1
fi

SLICE_NUM="$1"
shift

SKIP_TESTS=false
SKIP_GATE=false
CONTEXT_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-tests) SKIP_TESTS=true ;;
    --skip-gate)  SKIP_GATE=true ;;
    --skip-all)   SKIP_TESTS=true; SKIP_GATE=true ;;
    --context)
      shift
      if [[ $# -eq 0 ]]; then
        echo "ERROR: --context requires a file path argument"
        exit 1
      fi
      if [[ ! -f "$1" ]]; then
        echo "ERROR: context file not found: $1"
        exit 1
      fi
      CONTEXT_FILES+=("$1")
      ;;
    *)
      echo "Unknown flag: $1"
      exit 1
      ;;
  esac
  shift
done

OUTPUT_DIR="$ROOT/ci-review/slice-reviews"
OUTPUT_FILE="$OUTPUT_DIR/slice-${SLICE_NUM}-prompt.md"
DIFF_FILE="$OUTPUT_DIR/slice-${SLICE_NUM}.diff"
BASELINE_FILE="$ROOT/ci-review/baseline.json"
REFACTORING_PLAN="$ROOT/docs/refactoring-plan.md"

mkdir -p "$OUTPUT_DIR"

# -------------------------------------------------------
# Validate prerequisites
# -------------------------------------------------------
# Auto-refresh baseline from merge-base with main if stale.
# "Stale" means the baseline was captured on a different commit than
# the current merge-base (i.e., main has moved since last snapshot).
MERGE_BASE=$(git merge-base main HEAD 2>/dev/null || echo "")
if [[ -n "$MERGE_BASE" ]]; then
  BASELINE_SHA=""
  if [[ -f "$BASELINE_FILE" ]]; then
    BASELINE_SHA=$(jq -r '.git_sha // ""' "$BASELINE_FILE" 2>/dev/null || echo "")
  fi
  MERGE_BASE_SHORT=$(git rev-parse --short "$MERGE_BASE")
  if [[ "$BASELINE_SHA" != "$MERGE_BASE_SHORT" ]]; then
    echo "=== Baseline stale (was $BASELINE_SHA, need $MERGE_BASE_SHORT) — refreshing ==="
    BASELINE_TMP=$(mktemp)
    git stash -q 2>/dev/null || true
    git checkout -q "$MERGE_BASE" 2>/dev/null
    bash tool/metrics.sh > "$BASELINE_TMP"
    git checkout -q - 2>/dev/null
    git stash pop -q 2>/dev/null || true
    mv "$BASELINE_TMP" "$BASELINE_FILE"
    echo "  Baseline updated to $MERGE_BASE_SHORT"
  fi
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "ERROR: Baseline not found: $BASELINE_FILE"
  echo "Run: bash tool/metrics.sh > ci-review/baseline.json"
  exit 1
fi

if [[ ! -f "$REFACTORING_PLAN" ]]; then
  echo "ERROR: Refactoring plan not found: $REFACTORING_PLAN"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed"
  exit 1
fi

# -------------------------------------------------------
# Tempfiles — cleaned on exit
# -------------------------------------------------------
METRICS_AFTER=$(mktemp)
GATE_OUTPUT=$(mktemp)
trap 'rm -f "$METRICS_AFTER" "$GATE_OUTPUT"' EXIT

# -------------------------------------------------------
# Phase 1: Run tests (unless --skip-tests)
# -------------------------------------------------------
if [[ "$SKIP_TESTS" == false ]]; then
  echo "=== Phase 1: Running tests ==="
  set +e
  bash tool/test_platform_interface.sh
  bash tool/test_ffi.sh
  if command -v cargo &>/dev/null; then
    bash tool/test_rust.sh
  else
    echo "  (skipping Rust tests — cargo not installed)"
  fi
  set -e
else
  echo "=== Phase 1: SKIPPED (--skip-tests) ==="
fi

# -------------------------------------------------------
# Phase 2: Run metrics.sh → tempfile JSON
# -------------------------------------------------------
echo "=== Phase 2: Capturing metrics ==="
bash tool/metrics.sh > "$METRICS_AFTER"

# -------------------------------------------------------
# Phase 3: Run gate.sh (unless --skip-gate)
# -------------------------------------------------------
if [[ "$SKIP_GATE" == false ]]; then
  echo "=== Phase 3: Running gate ==="
  set +e
  bash tool/gate.sh > "$GATE_OUTPUT" 2>&1
  GATE_EXIT=$?
  set -e
  if [[ $GATE_EXIT -eq 0 ]]; then
    GATE_STATUS="PASSED"
    # Clean summary only
    GATE_SUMMARY=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$GATE_OUTPUT" \
      | awk '/GATE SUMMARY/,0' \
      | grep -v '^===' \
      | sed '/^$/d')
  else
    GATE_STATUS="FAILED (exit $GATE_EXIT)"
    # On failure, include the last 80 lines so the reviewer can see why
    GATE_SUMMARY="GATE FAILED. Tail of failure log:

$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$GATE_OUTPUT" | tail -80)"
  fi
else
  echo "=== Phase 3: SKIPPED (--skip-gate) ==="
  GATE_STATUS="SKIPPED"
  GATE_SUMMARY="(gate skipped via --skip-gate)"
fi

# -------------------------------------------------------
# Phase 4: Collect git data + unified diff
# -------------------------------------------------------
echo "=== Phase 4: Collecting git data ==="
GIT_SHA=$(git rev-parse --short HEAD)
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
GIT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DIFF_STAT=$(git diff main --stat 2>/dev/null || echo "(could not diff against main)")

# Generate unified diff — exclude lockfiles and generated code
git diff main -- . ':(exclude)*.lock' ':(exclude)*.g.dart' > "$DIFF_FILE" 2>/dev/null
DIFF_SIZE=$(wc -c < "$DIFF_FILE" | tr -d ' ')

# Collect changed source/test files (skip docs, config, deleted files)
CHANGED_FILES=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ ! -f "$ROOT/$file" ]] && continue
  case "$file" in
    *.md|*.yaml|*.yml|*.toml|*.json|*.lock) continue ;;
  esac
  CHANGED_FILES+=("$file")
done < <(git diff main --name-only 2>/dev/null)

# -------------------------------------------------------
# Phase 5: Extract slice spec from refactoring-plan.md
# -------------------------------------------------------
echo "=== Phase 5: Extracting slice spec ==="
SLICE_SPEC=$(awk "
  /^## Slice ${SLICE_NUM}:/ { found=1; print; next }
  found && /^---\$/ { exit }
  found && /^## Slice [0-9]/ { exit }
  found { print }
" "$REFACTORING_PLAN")

if [[ -z "$SLICE_SPEC" ]]; then
  SLICE_SPEC="(Slice $SLICE_NUM spec not found in $REFACTORING_PLAN)"
fi

# -------------------------------------------------------
# Phase 6: Extract review rubric
# -------------------------------------------------------
echo "=== Phase 6: Extracting review rubric ==="
REVIEW_RUBRIC=$(awk '
  /^\*\*Review process/ { found=1; print; next }
  found && /^Review output goes to/ { exit }
  found { print }
' "$REFACTORING_PLAN")

if [[ -z "$REVIEW_RUBRIC" ]]; then
  REVIEW_RUBRIC="(Review rubric not found in $REFACTORING_PLAN)"
fi

# -------------------------------------------------------
# Phase 7: Parse both JSONs with jq, compute delta table
# -------------------------------------------------------
echo "=== Phase 7: Computing metrics delta ==="

pkg_metric() {
  local file="$1" pkg="$2" field="$3"
  jq -r ".packages.\"$pkg\".\"$field\" // \"N/A\"" "$file"
}

delta() {
  local before="$1" after="$2"
  if [[ "$before" == "N/A" || "$before" == "null" || "$after" == "N/A" || "$after" == "null" ]]; then
    echo "—"
  else
    local d=$(( after - before ))
    if [[ $d -gt 0 ]]; then echo "+$d"
    elif [[ $d -eq 0 ]]; then echo "0"
    else echo "$d"
    fi
  fi
}

DART_PACKAGES=(
  dart_monty_platform_interface
  dart_monty_ffi
  dart_monty_wasm
  dart_monty_web
  dart_monty_desktop
)

# Build condensed metrics: only packages with non-zero deltas + containment note
AFFECTED_PKGS=()
UNAFFECTED_PKGS=()
METRICS_LINES=""

for pkg in "${DART_PACKAGES[@]}"; do
  has_delta=false
  for field in source_lines test_lines test_count coverage_pct; do
    b=$(pkg_metric "$BASELINE_FILE" "$pkg" "$field")
    a=$(pkg_metric "$METRICS_AFTER" "$pkg" "$field")
    d=$(delta "$b" "$a")
    if [[ "$d" != "0" && "$d" != "—" ]]; then
      has_delta=true
    fi
  done
  if [[ "$has_delta" == true ]]; then
    AFFECTED_PKGS+=("$pkg")
    src_b=$(pkg_metric "$BASELINE_FILE" "$pkg" "source_lines")
    src_a=$(pkg_metric "$METRICS_AFTER" "$pkg" "source_lines")
    src_d=$(delta "$src_b" "$src_a")
    tst_b=$(pkg_metric "$BASELINE_FILE" "$pkg" "test_lines")
    tst_a=$(pkg_metric "$METRICS_AFTER" "$pkg" "test_lines")
    tst_d=$(delta "$tst_b" "$tst_a")
    cnt_b=$(pkg_metric "$BASELINE_FILE" "$pkg" "test_count")
    cnt_a=$(pkg_metric "$METRICS_AFTER" "$pkg" "test_count")
    cnt_d=$(delta "$cnt_b" "$cnt_a")
    cov_a=$(pkg_metric "$METRICS_AFTER" "$pkg" "coverage_pct")
    METRICS_LINES="$METRICS_LINES
- **$pkg**: source ${src_d} (${src_a}), tests ${tst_d} (${tst_a} lines, ${cnt_a} tests), coverage ${cov_a}%"
  else
    UNAFFECTED_PKGS+=("$pkg")
  fi
done

METRICS_SUMMARY="**Affected packages:**$METRICS_LINES"
if [[ ${#UNAFFECTED_PKGS[@]} -gt 0 ]]; then
  UNAFFECTED_LIST=$(printf '%s' "${UNAFFECTED_PKGS[0]}"; printf ', %s' "${UNAFFECTED_PKGS[@]:1}")
  METRICS_SUMMARY="$METRICS_SUMMARY
- **Containment:** No changes in ${UNAFFECTED_LIST}."
fi

# -------------------------------------------------------
# Phase 8: Build file list for read_files
# -------------------------------------------------------
echo "=== Phase 8: Building file list ==="

# Build JSON array: prompt file + diff file + changed source + context files
FILES_JSON="[\"$OUTPUT_FILE\",\"$DIFF_FILE\""
if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
  for file in "${CHANGED_FILES[@]}"; do
    FILES_JSON="$FILES_JSON,\"$ROOT/$file\""
  done
fi
if [[ ${#CONTEXT_FILES[@]} -gt 0 ]]; then
  for file in "${CONTEXT_FILES[@]}"; do
    # Resolve relative paths to absolute
    if [[ "$file" = /* ]]; then
      FILES_JSON="$FILES_JSON,\"$file\""
    else
      FILES_JSON="$FILES_JSON,\"$ROOT/$file\""
    fi
  done
fi
FILES_JSON="$FILES_JSON]"

FILE_COUNT=$(( 2 + ${#CHANGED_FILES[@]} + ${#CONTEXT_FILES[@]} ))

# -------------------------------------------------------
# Phase 9: Assemble prompt markdown (lean — no file contents)
# -------------------------------------------------------
echo "=== Phase 9: Assembling prompt ==="

cat > "$OUTPUT_FILE" << PROMPT
# Slice $SLICE_NUM Review

You are a strict, adversarial Principal Engineer reviewing refactoring
Slice $SLICE_NUM for the dart_monty project. Do not trust the author's
stated intentions — verify every claim against the unified diff.

The unified diff is provided as \`slice-${SLICE_NUM}.diff\`. The changed
source files are provided alongside this prompt. Read the diff first,
then cross-reference with the source files. Any additional files after the
changed sources are **context files** — unchanged pre-existing code included
so you can verify claims about existing infrastructure without guessing.

**Branch:** $GIT_BRANCH | **SHA:** $GIT_SHA | **Date:** $GIT_DATE

---

## Review Instructions

$REVIEW_RUBRIC

---

## Slice Spec

$SLICE_SPEC

---

## Diff Stats

\`\`\`
$DIFF_STAT
\`\`\`

## Metrics Summary

$METRICS_SUMMARY

## Gate: $GATE_STATUS

$GATE_SUMMARY

---

*Generated by tool/slice_review.sh*
PROMPT

# -------------------------------------------------------
# Done
# -------------------------------------------------------
OUTPUT_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
echo ""
echo "========================================"
echo "  Slice $SLICE_NUM review ready"
echo "  Prompt:  $OUTPUT_FILE ($OUTPUT_SIZE bytes)"
echo "  Diff:    $DIFF_FILE ($DIFF_SIZE bytes)"
echo "  Files:   $FILE_COUNT total (prompt + diff + ${#CHANGED_FILES[@]} source + ${#CONTEXT_FILES[@]} context)"
echo "  Gate:    $GATE_STATUS"
echo "========================================"
echo ""
echo "Next step:"
echo ""
echo "  mcp__gemini__read_files("
echo "    file_paths=$FILES_JSON,"
echo "    prompt=\"You are a strict Principal Engineer. Review this slice."
echo "      The first file is the review prompt with rubric and metrics."
echo "      The second file is the unified diff — read it carefully."
echo "      Files after the diff are changed source files, followed by"
echo "      context files (unchanged, for verifying pre-existing state)."
echo "      Follow the review instructions exactly.\","
echo "    model=\"gemini-3.1-pro-preview\""
echo "  )"
