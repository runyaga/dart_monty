# WASM Re-Entrancy Spike: Findings

> **Date:** 2026-02-28
> **Branch:** `spike/wasm-reentrant-deadlock`
> **Platform:** Chrome headless, macOS, Node 22, Dart SDK 3.5+

## Results

| Scenario | Result | Notes |
|----------|--------|-------|
| 1. Happy path | **PASS** | Suspend/resume round-trip: 40ms |
| 2. Re-entrancy guard | **PASS** | `StateError` thrown immediately (0ms), resume succeeded after |
| 3. Error recovery | **PASS** | Python caught the injected error: `"caught: ReentrantCallBlocked: cannot enter Python while suspended"` (1ms) |
| 4. Concurrent work | **PASS** | 4 sequential suspend/resume cycles completed. Final value: `"Legal: contract looks good, Finance: projections positive"` (1ms) |
| 5. CPU-bound timeout | **FAIL** | `MontyLimits(timeoutMs: 2000)` did not fire. Dart-side 15s safety timeout triggered. Worker thread unresponsive during infinite loop. |

## Measured Latencies

- Suspend/resume round-trip (Scenario 1): **40ms** (includes Worker init on first call)
- Subsequent suspend/resume cycles: **<1ms** each (Scenarios 2-4)
- Error recovery overhead (resumeWithError): **1ms**
- Re-entrancy guard check: **synchronous** (0ms, fires before any Worker message)

## Memory Behavior

- Does the WASM interpreter leak on error recovery? **No observable leak.** Each scenario used a fresh `MontyWasm` instance. `resumeWithError()` completed cleanly and the interpreter state survived.

## Event Loop Responsiveness

- Scenarios 1-4: Dart event loop **stayed fully responsive** — Python runs in a Web Worker, not the main thread.
- Scenario 5: Dart event loop **stayed responsive** (the 15s safety `Future.timeout()` fired on schedule), but the Worker thread was blocked. The Worker-based architecture isolates the main thread even when Python is in an infinite loop.

## Key Architectural Discovery

The WASM backend runs Python in a **Web Worker** (separate thread). This means:

1. The Dart event loop is **never blocked** by Python execution.
2. The re-entrancy guard (`MontyStateMixin.assertIdle()`) fires **synchronously on the main thread** before any Worker message is sent. It doesn't need the Worker to be responsive.
3. `resumeWithError()` sends a message to the Worker, which raises a Python exception. The Worker processes this and sends back the result. Works perfectly.
4. `MontyLimits.timeoutMs` is translated to `maxDurationSecs` and passed to the Monty WASM runtime inside the Worker. The runtime **cannot enforce it** during a CPU-bound loop — WASM has no preemptive interruption mechanism.

## Why Scenario 5 Fails

The timeout limit is passed to the Monty WASM runtime as `maxDurationSecs`. Inside the Worker, the Python interpreter runs synchronously in a WASM `while True` loop. WASM execution is **non-preemptible** — there is no mechanism for the host (JS Worker thread) to interrupt a running WASM function. The timeout check can only fire between bytecode operations if the runtime implements fuel/instruction counting, which the current `@pydantic/monty-wasm32-wasi` binary does not.

The main thread remains responsive (timers fire, UI updates work) because the Worker is a separate OS thread. But the Worker itself is stuck.

## Recommendation

**WASM is safe for Layer 0-2 orchestration. Layer 3 CPU-bound scripts need mitigation.**

Scenarios 1-4 passing means:
- `wait_all()` pattern works on WASM (suspend Python, process multiple SSE streams, resume)
- Re-entrancy guard prevents deadlocks
- Error recovery chain works end-to-end (Dart catches → packages error → `resumeWithError()` → Python `except` block)
- Sequential multi-host-call orchestration works with state preserved across calls

For Scenario 5 (CPU-bound timeout), the options from the spike plan apply:

1. **Worker termination + restart** (recommended short-term): The main thread can `Worker.terminate()` the hung Worker after a Dart-side timeout, then create a new Worker. This loses the Python execution state but prevents the tab from accumulating stuck Workers.

2. **WASM fuel/instruction counting** (recommended long-term): Add instruction-count limits to the Monty WASM runtime (similar to Lua's `debug.sethook`). This would allow the runtime to check elapsed time every N bytecodes and throw a timeout exception from within WASM.

3. **Restrict WASM to yielding scripts only** (acceptable fallback): Scripts that make host function calls naturally yield to the event loop. Only pure CPU-bound scripts (no external calls) would hang. Since Soliplex scripts are orchestration-focused (they call `spawn_agent`, `wait_all`, etc.), most real scripts yield frequently. Pure computation scripts could be restricted to native clients via `PlatformConstraints`.
