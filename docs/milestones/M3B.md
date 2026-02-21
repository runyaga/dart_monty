# M3B: Web Viability Spike

## Goal

Prove Dart WASM + JS interop can load and run Monty in a browser.
This is the GO/NO-GO decision for web support.

## Risk Addressed

- **R1** (web WASM/WASI viability) — validated with pure Dart, no Flutter

## Prerequisites

- M2 (Rust C FFI + WASM build) complete
- M3A (Native FFI package) complete

## Deliverables

- `spike/web_test/main.dart` — Dart program using `dart:js_interop`
- `spike/web_test/index.html` — loads Monty WASM (from M2) + Dart WASM
- `tool/test_web_spike.sh` — build + headless Chrome verification

## Work Items

### 3B.1 Web Spike Implementation

- [ ] `spike/web_test/main.dart` using `dart:js_interop`
- [ ] `spike/web_test/index.html` with COOP/COEP headers
- [ ] Compile: `dart compile wasm spike/web_test/main.dart`
- [ ] Verify: Python code executes in browser via Dart WASM -> JS -> Monty WASM

### 3B.2 Web Spike Automation

- [ ] `tool/test_web_spike.sh`:
  1. Build Monty WASM (from M2)
  2. `dart compile wasm` the spike
  3. Start local server with COOP/COEP headers
  4. Run headless Chrome, capture console output
  5. Assert expected result

## Decision Point

| Outcome | Action |
|---------|--------|
| Web spike passes | Proceed to M4 (Dart WASM) and M6 (Flutter web) |
| Web spike fails (fixable) | Investigate, document fix, retry |
| Web spike fails (fundamental) | Drop web phases, native-only project |
