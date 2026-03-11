# Plugin Wrap Process Tutorial

Generate a MontyPlugin wrapper for any pub.dev package using a local LLM.

## Prerequisites

- Dart SDK 3.5+
- Python 3.10+
- An LLM backend (Ollama recommended for offline use)
- Native Monty library built (`cd native && cargo build --release`)

## Quick Start

```bash
# Default: local Ollama with qwen2.5-coder:14b
bash tool/test_wrap_process.sh phone_numbers_parser

# Specific model on a remote Ollama server
OLLAMA_HOST=http://gpu-server:11434 LLM_MODEL=gpt-oss:120b \
  bash tool/test_wrap_process.sh uuid

# Gemini cloud
LLM_PROVIDER=gemini GEMINI_API_KEY=... \
  bash tool/test_wrap_process.sh path
```

## How It Works

The wrap process is a **three-stage pipeline**:

### Stage 1: WRAP (agentic TDD loop)

1. **Fetch** package info from pub.dev + README from GitHub
2. **Scaffold** a clean-room Dart project with `very_good_analysis`
3. **Build prompts** — system prompt (RULES + PLUGIN-CONTRACT.md) + user prompt (package description + README)
4. **Iterate**:
   - Call LLM to generate plugin + test code
   - Extract code blocks from markdown response
   - `dart fix --apply` + `dart format` (mechanical lint fixes)
   - `dart analyze --fatal-infos` — if fail, feed errors back to LLM
   - `dart test` — if fail, feed errors back to LLM
   - Repeat until pass or max iterations reached

### Stage 2: PRELUDE_LINT (static analysis)

Checks the generated `pythonPrelude` for Monty-unsafe Python patterns:
- `for x in items:` (use `while` loop)
- f-strings (use `str()` + concatenation)
- `import`, `try/except`, `class`, `lambda`, list comprehensions
- Any other syntax not in the Monty Python subset

### Stage 3: MONTY_SMOKE (integration test)

If the native Monty library is available:
1. Adds `dart_monty_ffi` + `dart_monty_platform_interface` to the clean room
2. Generates a Dart test that creates a real `DefaultMontyBridge`
3. Registers the plugin via `PluginRegistry`
4. Runs the `pythonPrelude` through the Monty interpreter
5. Calls every wrapper function through Monty and verifies no errors

## Pipeline Outputs

Each run creates a timestamped directory under `wrap-runs/<package>/`:

```
wrap-runs/uuid/2026-03-10_22-48-56/
  report.json           # Structured results (iterations, durations, status)
  report.txt            # Human-readable summary
  run.log.jsonl         # Machine-parseable event log
  conversation.jsonl    # Full LLM conversation history
  workspace/            # The clean-room Dart project
    lib/src/plugins/uuid_plugin.dart      # Generated plugin
    test/src/plugins/uuid_plugin_test.dart # Generated unit tests
    test/src/plugins/uuid_smoke_test.dart  # Generated Monty smoke test
  artifacts/
    system_prompt.txt   # System prompt sent to LLM
    initial_prompt.txt  # First user message
    readme.md           # Fetched library README
    iter_N_response.md  # LLM response per iteration
    iter_N_plugin.dart  # Extracted plugin code per iteration
    iter_N_test.dart    # Extracted test code per iteration
    iter_N_analyze.txt  # dart analyze output per iteration
    iter_N_test_output.txt  # dart test output (when analyze passes)
    turns/turn_NNN.json # Multi-turn conversation state
    smoke_test.dart     # Generated Monty smoke test (copy)
    prelude_lint.txt    # Prelude lint results
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LLM_PROVIDER` | `ollama` | `ollama`, `openai`, or `gemini` |
| `LLM_MODEL` | per-provider | Model name (e.g., `gpt-oss:120b`) |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama server URL |
| `OPENAI_BASE_URL` | `http://localhost:11434/v1` | OpenAI-compatible endpoint |
| `OPENAI_API_KEY` | — | API key for OpenAI provider |
| `GEMINI_API_KEY` | — | API key for Gemini provider |
| `WRAP_MAX_ITERATIONS` | 8/5/3 | Max fix iterations (ollama/openai/gemini) |
| `DART_MONTY_BRIDGE` | auto-detected | Path to dart_monty_bridge package |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | SUCCESS — all stages passed |
| 1 | FAILURE or PARTIAL — WRAP failed, or add-on stage failed |
| 2 | Setup failure (bad args, missing deps) |
| 3 | LLM failure (API error, no code blocks) |

## Tool Scripts

| Script | Purpose |
|--------|---------|
| `tool/test_wrap_process.sh` | Main harness — orchestrates all stages |
| `tool/llm_call.py` | Provider-agnostic LLM API caller |
| `tool/extract_code_blocks.py` | Extracts Dart code blocks from LLM markdown |
| `tool/generate_report.py` | Generates JSON report from run data |
| `tool/lint_prelude.py` | Static linter for pythonPrelude |
| `tool/generate_smoke_test.py` | Generates Monty integration smoke test |

## Design Decisions

### Why `dart fix --apply` before `dart analyze`?

Local models (20B-120B params) consistently miss `very_good_analysis` lint
rules like `const` constructors, nullable casts, and trailing commas.
`dart fix` resolves 60-80% of these mechanically, letting the LLM focus on
semantic correctness.

### Why disable `lines_longer_than_80_chars` and `require_trailing_commas`?

LLMs cannot reliably count characters or manage trailing comma placement.
These rules wasted 1-3 iterations per run with no semantic benefit. Disabling
them in the clean room's `analysis_options.yaml` is a pragmatic tradeoff.

### Why provider-aware iteration defaults?

Cloud models (Gemini, GPT-4o) typically solve in 1-3 iterations. Local models
need 3-8. Giving each provider an appropriate budget avoids both premature
failure and wasted compute.

### Why loop detection?

If the LLM produces identical error output for two consecutive iterations,
it's stuck. The harness aborts early with a `STUCK` status instead of burning
remaining iterations on the same error.

### Why `_help_docs = {}` in the smoke test?

The Monty runtime normally initializes `_help_docs` and `_help_list` globals
before plugin preludes run. In bare-bridge mode (no full runtime), the smoke
test must initialize these itself so the prelude's help registration works.
