# WASM Re-Entrancy Spike

Validates the suspend/resume/error chain on the Monty WASM bridge.

## Quick Start

```bash
cd spike/wasm_reentrant

# 1. Install dependencies
dart pub get

# 2. Copy WASM assets
cp ../../packages/dart_monty_wasm/assets/* web/

# 3. Compile Dart to JS
dart compile js bin/main.dart -o web/main.dart.js

# 4. Serve with COOP/COEP headers
node serve.mjs

# 5. Open http://localhost:8080 — results appear on page and in console
```

## Scenarios

1. **Happy path** — basic suspend/resume cycle
2. **Re-entrancy guard** — StateError on concurrent start()
3. **Error recovery** — resumeWithError() + Python try/except
4. **Multi-call flow** — 4 sequential host calls
5. **CPU-bound timeout** — MontyLimits.timeoutMs on infinite loop

## Output

Results appear in the browser console and rendered on the page.
Findings should be written to `FINDINGS.md` after the run.
