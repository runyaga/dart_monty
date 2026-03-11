#!/usr/bin/env bash
# test_wrap_process.sh — Automated test harness for the plugin wrap process.
#
# Generates a MontyPlugin wrapper for a pub.dev package using an LLM,
# then validates it with dart analyze + dart test, iterating on errors.
#
# Usage:
#   bash tool/test_wrap_process.sh <package_name> [output_dir]
#
# Examples:
#   # Local Ollama (default — works offline):
#   bash tool/test_wrap_process.sh phone_numbers_parser
#
#   # Specific Ollama model:
#   LLM_MODEL=qwen2.5-coder:32b bash tool/test_wrap_process.sh path
#
#   # Gemini cloud:
#   LLM_PROVIDER=gemini GEMINI_API_KEY=... bash tool/test_wrap_process.sh uuid
#
#   # OpenAI-compatible (LM Studio, vLLM, etc.):
#   LLM_PROVIDER=openai OPENAI_BASE_URL=http://localhost:1234/v1 \
#     bash tool/test_wrap_process.sh collection
#
# Environment:
#   LLM_PROVIDER         — ollama (default), openai, gemini
#   LLM_MODEL            — Model name. Defaults per provider:
#                          ollama: qwen2.5-coder:14b
#                          openai: gpt-4o
#                          gemini: gemini-2.5-pro
#   OLLAMA_HOST          — Ollama server URL (default: http://localhost:11434)
#   OPENAI_BASE_URL      — OpenAI-compatible endpoint (default: http://localhost:11434/v1)
#   OPENAI_API_KEY       — Optional for OpenAI-compatible endpoints
#   GEMINI_API_KEY       — Required for gemini provider
#   WRAP_MAX_ITERATIONS  — Max fix iterations (default: 8 ollama, 5 openai, 3 gemini)
#   DART_MONTY_BRIDGE    — Path to dart_monty_bridge package (auto-detected)
#
# Exit codes:
#   0 — Success (plugin generated and validated)
#   1 — Failure (max iterations reached)
#   2 — Setup failure (bad args, missing deps, pub get failed)
#   3 — LLM failure (API error, no code blocks extracted)

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

LLM_PROVIDER="${LLM_PROVIDER:-ollama}"

# Default iteration count: higher for local models which need more attempts.
if [[ -z "${WRAP_MAX_ITERATIONS:-}" ]]; then
  case "$LLM_PROVIDER" in
    ollama)  MAX_ITERATIONS=8 ;;
    openai)  MAX_ITERATIONS=5 ;;
    gemini)  MAX_ITERATIONS=3 ;;
    *)       MAX_ITERATIONS=5 ;;
  esac
else
  MAX_ITERATIONS="$WRAP_MAX_ITERATIONS"
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT_FILE="$PROJECT_ROOT/docs/PLUGIN-CONTRACT.md"
BRIDGE_PATH="${DART_MONTY_BRIDGE:-$PROJECT_ROOT/packages/dart_monty_bridge}"
EXTRACTOR="$SCRIPT_DIR/extract_code_blocks.py"
REPORTER="$SCRIPT_DIR/generate_report.py"
LLM_CALLER="$SCRIPT_DIR/llm_call.py"

# Default models per provider.
case "$LLM_PROVIDER" in
  ollama)  LLM_MODEL="${LLM_MODEL:-qwen2.5-coder:14b}" ;;
  openai)  LLM_MODEL="${LLM_MODEL:-gpt-4o}" ;;
  gemini)  LLM_MODEL="${LLM_MODEL:-gemini-2.5-pro}" ;;
  *)
    echo "ERROR: Unknown LLM_PROVIDER '$LLM_PROVIDER'. Use: ollama, openai, gemini" >&2
    exit 2
    ;;
esac

# ─── Argument parsing ──────────────────────────────────────────────────────

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <package_name> [output_dir]"
  echo ""
  echo "Environment:"
  echo "  LLM_PROVIDER=ollama|openai|gemini  (default: ollama)"
  echo "  LLM_MODEL=<model_name>             (default: per provider)"
  echo "  WRAP_MAX_ITERATIONS=3              (default: 3)"
  exit 2
fi

PACKAGE_NAME="$1"
OUTPUT_BASE="${2:-$PROJECT_ROOT/wrap-runs}"

# ─── Preflight checks ─────────────────────────────────────────────────────

for cmd in dart python3 curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not found on PATH." >&2
    exit 2
  fi
done

if [[ ! -f "$CONTRACT_FILE" ]]; then
  echo "ERROR: PLUGIN-CONTRACT.md not found at $CONTRACT_FILE" >&2
  exit 2
fi

if [[ ! -d "$BRIDGE_PATH" ]]; then
  echo "ERROR: dart_monty_bridge not found at $BRIDGE_PATH" >&2
  exit 2
fi

# Provider-specific checks.
if [[ "$LLM_PROVIDER" == "gemini" && -z "${GEMINI_API_KEY:-}" ]]; then
  echo "ERROR: GEMINI_API_KEY required for gemini provider." >&2
  exit 2
fi

if [[ "$LLM_PROVIDER" == "ollama" ]]; then
  OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
  if ! curl -s --max-time 5 "$OLLAMA_HOST/api/tags" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to Ollama at $OLLAMA_HOST" >&2
    echo "Start Ollama with: ollama serve" >&2
    exit 2
  fi
  echo "--- Ollama is running at $OLLAMA_HOST"
fi

# ─── Run directory setup ───────────────────────────────────────────────────

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
RUN_DIR="$OUTPUT_BASE/$PACKAGE_NAME/$TIMESTAMP"
WORKSPACE="$RUN_DIR/workspace"
ARTIFACTS="$RUN_DIR/artifacts"
TURNS_DIR="$ARTIFACTS/turns"
LOG_FILE="$RUN_DIR/run.log.jsonl"
CONVO_FILE="$RUN_DIR/conversation.jsonl"
REPORT_JSON="$RUN_DIR/report.json"
REPORT_TXT="$RUN_DIR/report.txt"
ITERATIONS_FILE="$ARTIFACTS/iterations.json"

mkdir -p "$WORKSPACE/lib/src/plugins" "$WORKSPACE/test/src/plugins" "$ARTIFACTS" "$TURNS_DIR"

echo '[]' > "$ITERATIONS_FILE"

# ─── Helpers ───────────────────────────────────────────────────────────────

log_event() {
  local stage="$1" level="$2" message="$3"
  python3 -c "
import json, sys
entry = {'stage': sys.argv[1], 'level': sys.argv[2], 'message': sys.argv[3]}
print(json.dumps(entry))
" "$stage" "$level" "$message" >> "$LOG_FILE"
}

log_event_file() {
  local stage="$1" level="$2" message="$3" data_file="$4"
  python3 -c "
import json, sys
entry = {'stage': sys.argv[1], 'level': sys.argv[2], 'message': sys.argv[3], 'data_file': sys.argv[4]}
print(json.dumps(entry))
" "$stage" "$level" "$message" "$data_file" >> "$LOG_FILE"
}

log_convo() {
  local role="$1" content_file="$2"
  python3 -c "
import json, sys
entry = {'role': sys.argv[1], 'content_file': sys.argv[2]}
print(json.dumps(entry))
" "$role" "$content_file" >> "$CONVO_FILE"
}

PREV_ERROR_HASH=""

# Detect if the model is stuck producing the same error.
check_stuck() {
  local error_file="$1"
  local current_hash
  current_hash=$(md5 -q "$error_file" 2>/dev/null || md5sum "$error_file" 2>/dev/null | cut -d' ' -f1)
  if [[ "$current_hash" == "$PREV_ERROR_HASH" ]]; then
    echo "    STUCK: Same error as previous iteration — aborting early."
    log_event "LOOP" "WARN" "Model stuck: identical error output for consecutive iterations"
    return 0  # stuck
  fi
  PREV_ERROR_HASH="$current_hash"
  return 1  # not stuck
}

TURN_INDEX=0

add_turn() {
  local role="$1" text_file="$2"
  local idx
  idx=$(printf "%03d" "$TURN_INDEX")
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    text = f.read()
turn = {'role': sys.argv[2], 'parts': [{'text': text}]}
json.dump(turn, sys.stdout)
" "$text_file" "$role" > "$TURNS_DIR/turn_${idx}.json"
  TURN_INDEX=$((TURN_INDEX + 1))
}

# Call the LLM via the provider-agnostic Python script.
call_llm() {
  local response_file="$1" system_file="$2"
  python3 "$LLM_CALLER" \
    --provider "$LLM_PROVIDER" \
    --model "$LLM_MODEL" \
    --system-file "$system_file" \
    --turns-dir "$TURNS_DIR" \
    --output "$response_file"
}

append_iteration() {
  local iter="$1" duration="$2" analyze_passed="$3" analyze_errors="$4" \
        test_passed="$5" test_count="$6" test_skipped="$7"
  python3 -c "
import json, sys
ifile = sys.argv[1]
with open(ifile) as f:
    iters = json.load(f)
entry = {
    'iteration': int(sys.argv[2]),
    'duration_seconds': int(sys.argv[3]),
    'analyze': {'passed': sys.argv[4] == 'true', 'error_count': int(sys.argv[5])},
    'test': {'passed': sys.argv[6] == 'true', 'test_count': int(sys.argv[7]) if sys.argv[7] != '0' else 0, 'skipped': sys.argv[8] == 'true'},
}
iters.append(entry)
with open(ifile, 'w') as f:
    json.dump(iters, f, indent=2)
" "$ITERATIONS_FILE" "$iter" "$duration" "$analyze_passed" "$analyze_errors" \
  "$test_passed" "$test_count" "$test_skipped"
}

# ─── Phase 1: Fetch package info from pub.dev ──────────────────────────────

echo "==> Wrap process: $PACKAGE_NAME"
echo "    Provider: $LLM_PROVIDER ($LLM_MODEL)"
echo "    Run dir:  $RUN_DIR"
echo "    Max iter: $MAX_ITERATIONS"
echo ""

log_event "SETUP" "INFO" "Starting wrap: $PACKAGE_NAME, provider=$LLM_PROVIDER, model=$LLM_MODEL"

echo "--- Fetching package info from pub.dev..."
PUB_INFO_FILE="$ARTIFACTS/pub_dev_info.json"

http_code=$(curl -s -w "%{http_code}" -o "$PUB_INFO_FILE" \
  -H "User-Agent: dart_monty-plugin-maker/1.0" \
  "https://pub.dev/api/packages/$PACKAGE_NAME")

if [[ "$http_code" != "200" ]]; then
  echo "ERROR: pub.dev returned HTTP $http_code for $PACKAGE_NAME" >&2
  log_event "PUB_DEV" "ERROR" "HTTP $http_code from pub.dev"
  exit 2
fi

LATEST_VERSION=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data['latest']['version'])
" "$PUB_INFO_FILE")

PACKAGE_DESC=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data['latest']['pubspec'].get('description', 'No description'))
" "$PUB_INFO_FILE")

log_event "PUB_DEV" "INFO" "Found $PACKAGE_NAME v$LATEST_VERSION"
echo "    $PACKAGE_NAME v$LATEST_VERSION"
echo "    $PACKAGE_DESC"

# Fetch README from GitHub (pub.dev renders via JS, curl can't get it).
echo "--- Fetching README..."
README_MD="$ARTIFACTS/readme.md"

python3 -c "
import json, sys, urllib.request, urllib.error, re

pub_info_file = sys.argv[1]
package_name = sys.argv[2]
output_file = sys.argv[3]

with open(pub_info_file) as f:
    data = json.load(f)

pubspec = data['latest']['pubspec']
repo = pubspec.get('repository', '') or pubspec.get('homepage', '') or ''

readme_text = ''

# Try GitHub raw README (supports github.com repos).
if 'github.com' in repo:
    # Extract owner/repo from URL.
    match = re.search(r'github\.com/([^/]+/[^/]+)', repo)
    if match:
        gh_repo = match.group(1).rstrip('/')
        for branch in ['main', 'master']:
            url = f'https://raw.githubusercontent.com/{gh_repo}/{branch}/README.md'
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'dart_monty/1.0'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    readme_text = resp.read().decode('utf-8', errors='replace')
                    break
            except urllib.error.HTTPError:
                continue
            except Exception:
                continue

# Fallback: minimal description.
if not readme_text or len(readme_text) < 100:
    desc = pubspec.get('description', 'No description')
    readme_text = f'# {package_name}\n\n{desc}\n\n(README could not be fetched from GitHub.)\n'

# Cap at 8K chars.
with open(output_file, 'w') as f:
    f.write(readme_text[:8000])

print(f'README: {len(readme_text[:8000])} bytes', file=sys.stderr)
" "$PUB_INFO_FILE" "$PACKAGE_NAME" "$README_MD" 2>&1

README_SIZE=$(wc -c < "$README_MD" | tr -d ' ')
log_event "PUB_DEV" "INFO" "README extracted ($README_SIZE bytes)"
echo "    README: $README_SIZE bytes"

# ─── Phase 2: Scaffold clean room ─────────────────────────────────────────

echo ""
echo "--- Scaffolding clean room..."

cat > "$WORKSPACE/pubspec.yaml" << YAML
name: wrap_test_${PACKAGE_NAME}
description: Clean room for wrapping ${PACKAGE_NAME}.
version: 0.0.1
publish_to: none

environment:
  sdk: ^3.5.0

dependencies:
  dart_monty_bridge:
    path: $BRIDGE_PATH
  $PACKAGE_NAME: ^$LATEST_VERSION

dev_dependencies:
  test: ^1.25.0
  very_good_analysis: ^6.0.0
YAML

cat > "$WORKSPACE/analysis_options.yaml" << 'YAML'
include: package:very_good_analysis/analysis_options.yaml

analyzer:
  language:
    strict-casts: true
    strict-raw-types: true

linter:
  rules:
    lines_longer_than_80_chars: false
YAML

log_event "SCAFFOLD" "INFO" "Clean room scaffolded"

echo "--- Running dart pub get..."
PUB_GET_OUTPUT="$ARTIFACTS/pub_get_output.txt"
if ! (cd "$WORKSPACE" && dart pub get) > "$PUB_GET_OUTPUT" 2>&1; then
  echo "ERROR: dart pub get failed" >&2
  cat "$PUB_GET_OUTPUT" >&2
  log_event_file "PUB_GET" "ERROR" "dart pub get failed" "$PUB_GET_OUTPUT"
  exit 2
fi
log_event "PUB_GET" "INFO" "dart pub get succeeded"
echo "    Dependencies resolved."

# ─── Phase 3: Build prompts ───────────────────────────────────────────────

SYSTEM_PROMPT_FILE="$ARTIFACTS/system_prompt.txt"
cat > "$SYSTEM_PROMPT_FILE" << 'SYSPROMPT'
You are a Dart plugin code generator. You generate MontyPlugin subclasses that
wrap Dart/Flutter libraries for use in the Monty Python sandbox.

RULES:
- Follow the plugin contract EXACTLY (provided below).
- Generated code must pass `dart analyze --fatal-infos` with zero issues
  using `very_good_analysis` (strict-casts, strict-raw-types enabled).
- Generated test file must pass `dart test`.
- Use only Monty-compatible Python in pythonPrelude (NO for-in, NO f-strings,
  NO imports, NO list comprehensions, NO try/except, NO range()).
- Use `while` loops with index for iteration in pythonPrelude.
- Use string concatenation, not f-strings, in pythonPrelude.
- Every host function must validate arguments with `is!` checks, throw ArgumentError.
- No bare `as` casts.
- No `// ignore:` directives.
- Return only JSON-safe types from handlers (Map, List, String, int, double, bool, null).
- Use single quotes for strings (unless the string contains a single quote).
- Sort dependencies alphabetically in any generated pubspec references.
- If you need to use classes or enums from the wrapped library in your tests,
  ensure you add the package import to the test file.
- In tests, use `final` (not `const`) when extracting values from library
  enums or objects for handler args.

Output EXACTLY two fenced code blocks with filename hints:
```dart:lib/src/plugins/<namespace>_plugin.dart
...code...
```
```dart:test/src/plugins/<namespace>_plugin_test.dart
...code...
```

PLUGIN CONTRACT:
SYSPROMPT

cat "$CONTRACT_FILE" >> "$SYSTEM_PROMPT_FILE"

INITIAL_PROMPT_FILE="$ARTIFACTS/initial_prompt.txt"
python3 -c "
import sys
package_name, version, description, readme_file = sys.argv[1:5]
with open(readme_file) as f:
    readme = f.read()
prompt = f'''Generate a MontyPlugin that wraps the \`{package_name}\` library (v{version}).

Package description: {description}

The package is already in pubspec.yaml as a dependency. Import it as:
\`import 'package:{package_name}/{package_name}.dart';\`

Import the plugin base as:
\`import 'package:dart_monty_bridge/dart_monty_bridge.dart';\`

The test file should import the plugin as:
\`import 'package:wrap_test_{package_name}/src/plugins/{package_name}_plugin.dart';\`

Here is the library documentation for API context:

{readme}

Choose the most useful 3-6 functions from the library to expose. Focus on the
primary use cases shown in the README. Each function MUST be prefixed with
the namespace you choose.'''
print(prompt)
" "$PACKAGE_NAME" "$LATEST_VERSION" "$PACKAGE_DESC" "$README_MD" > "$INITIAL_PROMPT_FILE"

log_event "PROMPT" "INFO" "Prompts built"

# ─── Phase 4: Agentic iteration loop ──────────────────────────────────────

add_turn "user" "$INITIAL_PROMPT_FILE"
log_convo "user" "$INITIAL_PROMPT_FILE"

PLUGIN_FILE="$WORKSPACE/lib/src/plugins/${PACKAGE_NAME}_plugin.dart"
TEST_FILE="$WORKSPACE/test/src/plugins/${PACKAGE_NAME}_plugin_test.dart"

START_TIME=$(date +%s)
FINAL_STATUS="FAILURE"
ITERATIONS_USED=0

echo ""
for ITER in $(seq 1 "$MAX_ITERATIONS"); do
  ITER_START=$(date +%s)
  ITERATIONS_USED=$ITER
  echo "=== Iteration $ITER/$MAX_ITERATIONS ==="
  log_event "ITERATION" "INFO" "Starting iteration $ITER"

  # ── 4a. Call LLM ──
  echo "    Calling $LLM_PROVIDER/$LLM_MODEL..."
  LLM_RESPONSE_MD="$ARTIFACTS/iter_${ITER}_response.md"

  if ! call_llm "$LLM_RESPONSE_MD" "$SYSTEM_PROMPT_FILE"; then
    echo "    ERROR: LLM call failed" >&2
    log_event "LLM" "ERROR" "Call failed on iteration $ITER"
    exit 3
  fi

  RESPONSE_SIZE=$(wc -c < "$LLM_RESPONSE_MD" | tr -d ' ')
  echo "    Response: $RESPONSE_SIZE bytes"
  log_event "LLM" "INFO" "Response received ($RESPONSE_SIZE bytes)"

  add_turn "model" "$LLM_RESPONSE_MD"
  log_convo "model" "$LLM_RESPONSE_MD"

  # ── 4b. Extract code blocks ──
  ITER_PLUGIN="$ARTIFACTS/iter_${ITER}_plugin.dart"
  ITER_TEST="$ARTIFACTS/iter_${ITER}_test.dart"

  if ! python3 "$EXTRACTOR" "$LLM_RESPONSE_MD" "$ITER_PLUGIN" "$ITER_TEST"; then
    echo "    ERROR: Code extraction failed" >&2
    log_event "EXTRACT" "ERROR" "Failed to extract code blocks on iteration $ITER"

    FIX_PROMPT="$ARTIFACTS/iter_${ITER}_fix_prompt.txt"
    cat > "$FIX_PROMPT" << 'FIXEOF'
Your previous response could not be parsed. The script failed to find two
separate ```dart code blocks.

Please regenerate the code and ensure you follow the output format EXACTLY:
- One code block for the plugin file, fenced as: ```dart:lib/src/plugins/<name>_plugin.dart
- One code block for the test file, fenced as: ```dart:test/src/plugins/<name>_plugin_test.dart

Do not add extra explanations outside the code blocks.
FIXEOF
    add_turn "user" "$FIX_PROMPT"
    log_convo "user" "$FIX_PROMPT"

    ITER_END=$(date +%s)
    append_iteration "$ITER" "$((ITER_END - ITER_START))" "false" "0" "false" "0" "true"
    echo ""
    continue
  fi

  cp "$ITER_PLUGIN" "$PLUGIN_FILE"
  cp "$ITER_TEST" "$TEST_FILE"

  # ── 4c. Auto-fix then analyze ──
  # Run dart fix first to resolve trivial lint issues the LLM commonly misses
  # (const constructors, nullable casts, redundant args, etc.)
  echo "    Running dart fix..."
  (cd "$WORKSPACE" && dart fix --apply) > "$ARTIFACTS/iter_${ITER}_fix_output.txt" 2>&1 || true
  # Also format to catch whitespace/line-length issues.
  (cd "$WORKSPACE" && dart format .) > /dev/null 2>&1 || true

  echo "    Running dart analyze..."
  ANALYZE_FILE="$ARTIFACTS/iter_${ITER}_analyze.txt"
  ANALYZE_EXIT=0
  (cd "$WORKSPACE" && dart analyze --fatal-infos) > "$ANALYZE_FILE" 2>&1 || ANALYZE_EXIT=$?

  if [[ $ANALYZE_EXIT -ne 0 ]]; then
    ANALYZE_ERRORS=$(grep -c "error\|warning\|info" "$ANALYZE_FILE" 2>/dev/null || echo "0")
    echo "    FAIL: dart analyze ($ANALYZE_ERRORS issues)"
    log_event_file "ANALYZE" "ERROR" "dart analyze failed ($ANALYZE_ERRORS issues)" "$ANALYZE_FILE"

    if check_stuck "$ANALYZE_FILE"; then
      ITER_END=$(date +%s)
      append_iteration "$ITER" "$((ITER_END - ITER_START))" "false" "$ANALYZE_ERRORS" "false" "0" "true"
      break
    fi

    FIX_PROMPT="$ARTIFACTS/iter_${ITER}_fix_prompt.txt"
    {
      echo '`dart analyze --fatal-infos` failed with these issues:'
      echo ''
      cat "$ANALYZE_FILE"
      echo ''
      echo 'Fix ALL issues. Output the complete updated files (both plugin and test)'
      echo 'as two fenced code blocks with the same filename format.'
    } > "$FIX_PROMPT"

    add_turn "user" "$FIX_PROMPT"
    log_convo "user" "$FIX_PROMPT"

    ITER_END=$(date +%s)
    append_iteration "$ITER" "$((ITER_END - ITER_START))" "false" "$ANALYZE_ERRORS" "false" "0" "true"
    echo ""
    continue
  fi

  echo "    PASS: dart analyze clean"
  log_event "ANALYZE" "INFO" "dart analyze passed"

  # ── 4d. dart test ──
  echo "    Running dart test..."
  TEST_OUTPUT_FILE="$ARTIFACTS/iter_${ITER}_test_output.txt"
  TEST_EXIT=0
  (cd "$WORKSPACE" && dart test) > "$TEST_OUTPUT_FILE" 2>&1 || TEST_EXIT=$?

  if [[ $TEST_EXIT -ne 0 ]]; then
    TEST_FAILURES=$(grep -c '\-[0-9]' "$TEST_OUTPUT_FILE" 2>/dev/null | tail -1 || echo "0")
    echo "    FAIL: dart test ($TEST_FAILURES failures)"
    log_event_file "TEST" "ERROR" "dart test failed" "$TEST_OUTPUT_FILE"

    if check_stuck "$TEST_OUTPUT_FILE"; then
      ITER_END=$(date +%s)
      append_iteration "$ITER" "$((ITER_END - ITER_START))" "true" "0" "false" "$TEST_FAILURES" "false"
      break
    fi

    FIX_PROMPT="$ARTIFACTS/iter_${ITER}_fix_prompt.txt"
    {
      echo '`dart analyze` passed, but `dart test` failed:'
      echo ''
      cat "$TEST_OUTPUT_FILE"
      echo ''
      echo 'Fix the implementation and/or the tests. Output the complete updated files'
      echo '(both plugin and test) as two fenced code blocks.'
    } > "$FIX_PROMPT"

    add_turn "user" "$FIX_PROMPT"
    log_convo "user" "$FIX_PROMPT"

    ITER_END=$(date +%s)
    append_iteration "$ITER" "$((ITER_END - ITER_START))" "true" "0" "false" "$TEST_FAILURES" "false"
    echo ""
    continue
  fi

  # ── SUCCESS ──
  TEST_PASS_COUNT=$(grep -oE '\+[0-9]+' "$TEST_OUTPUT_FILE" 2>/dev/null | tail -1 | tr -d '+' || echo "0")
  echo "    PASS: dart test ($TEST_PASS_COUNT tests)"
  log_event "TEST" "INFO" "dart test passed ($TEST_PASS_COUNT tests)"

  ITER_END=$(date +%s)
  append_iteration "$ITER" "$((ITER_END - ITER_START))" "true" "0" "true" "${TEST_PASS_COUNT:-0}" "false"

  FINAL_STATUS="SUCCESS"
  break
done

# ─── Phase 5: Generate reports ─────────────────────────────────────────────

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

echo ""
echo "================================================="

python3 "$REPORTER" \
  "$PACKAGE_NAME" \
  "$LATEST_VERSION" \
  "$TIMESTAMP" \
  "$LLM_PROVIDER/$LLM_MODEL" \
  "$MAX_ITERATIONS" \
  "$ITERATIONS_USED" \
  "$TOTAL_DURATION" \
  "$FINAL_STATUS" \
  "$RUN_DIR" \
  "$ITERATIONS_FILE" > "$REPORT_JSON"

{
  echo "================================================="
  echo "  Wrap Process Test Report"
  echo "================================================="
  echo "Package:     $PACKAGE_NAME v$LATEST_VERSION"
  echo "LLM:         $LLM_PROVIDER / $LLM_MODEL"
  echo "Run:         $TIMESTAMP"
  echo "Duration:    ${TOTAL_DURATION}s"
  echo "Iterations:  $ITERATIONS_USED / $MAX_ITERATIONS"
  echo "Status:      $FINAL_STATUS"
  echo ""
} > "$REPORT_TXT"

for ITER_NUM in $(seq 1 "$ITERATIONS_USED"); do
  echo "--- Iteration $ITER_NUM ---" >> "$REPORT_TXT"
  if [[ -f "$ARTIFACTS/iter_${ITER_NUM}_analyze.txt" ]]; then
    if grep -q "No issues found" "$ARTIFACTS/iter_${ITER_NUM}_analyze.txt" 2>/dev/null; then
      echo "  [PASS] dart analyze" >> "$REPORT_TXT"
    else
      ISSUES=$(grep -c "error\|warning\|info" "$ARTIFACTS/iter_${ITER_NUM}_analyze.txt" 2>/dev/null || echo "?")
      echo "  [FAIL] dart analyze: $ISSUES issues" >> "$REPORT_TXT"
    fi
  else
    echo "  [SKIP] dart analyze" >> "$REPORT_TXT"
  fi
  if [[ -f "$ARTIFACTS/iter_${ITER_NUM}_test_output.txt" ]]; then
    if grep -q "All tests passed" "$ARTIFACTS/iter_${ITER_NUM}_test_output.txt" 2>/dev/null; then
      echo "  [PASS] dart test" >> "$REPORT_TXT"
    else
      echo "  [FAIL] dart test" >> "$REPORT_TXT"
    fi
  else
    echo "  [SKIP] dart test" >> "$REPORT_TXT"
  fi
  echo "" >> "$REPORT_TXT"
done

{
  echo "================================================="
  echo "  RESULT: $FINAL_STATUS"
  echo "================================================="
} >> "$REPORT_TXT"

cat "$REPORT_TXT"

if [[ -f "$PLUGIN_FILE" ]]; then
  echo ""
  echo "Plugin: $PLUGIN_FILE"
  echo "Test:   $TEST_FILE"
fi

echo ""
echo "Artifacts: $ARTIFACTS"
echo "Report:    $REPORT_JSON"

# Show diffs between iterations.
if [[ $ITERATIONS_USED -gt 1 ]]; then
  echo ""
  echo "--- Diffs ---"
  for i in $(seq 2 "$ITERATIONS_USED"); do
    PREV=$((i - 1))
    if [[ -f "$ARTIFACTS/iter_${PREV}_plugin.dart" && -f "$ARTIFACTS/iter_${i}_plugin.dart" ]]; then
      echo "  iter_${PREV} -> iter_${i} (plugin):"
      diff -u "$ARTIFACTS/iter_${PREV}_plugin.dart" "$ARTIFACTS/iter_${i}_plugin.dart" \
        | head -20 || true
      echo ""
    fi
  done
fi

if [[ "$FINAL_STATUS" == "SUCCESS" ]]; then
  exit 0
else
  exit 1
fi
