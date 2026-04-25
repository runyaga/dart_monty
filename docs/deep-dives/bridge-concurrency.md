# Bridge concurrency and serialization

`MontyRuntime`'s underlying `PlatformBridge` serializes Python
execution strictly: **one `execute()` call per bridge at a time**.
A second `execute()` invoked while another is still running throws:

```text
StateError: Bridge is already executing
```

This contract is identical on both backends:

- **FFI (native)**: the bridge owns a single Rust REPL handle; the
  `_isExecuting` guard in `PlatformBridge` rejects overlapping calls
  before they reach the native library.
- **WASM (web)**: same `_isExecuting` guard in the shared
  `PlatformBridge` Dart code. The browser's "Worker pool
  architecture" (from `[DartMontyBridge]` console logs) enables
  parallelism *across* sessions — each `MontyRuntime` can run in its
  own worker — but *within* a single runtime, execution stays serial.

In short: parallel `MontyRuntime`s, yes. Parallel `execute()` on the
same runtime, no.

## Why this matters

A single conversation in an LLM-driven application typically owns one
`MontyRuntime` (one interpreter session). If the LLM chooses to
dispatch two tool calls in parallel — a pattern that is allowed by
the OpenAI-style tool-call protocol and that some planners use — the
second call hits the bridge-busy error before it starts.

Consumers that wrap `MontyRuntime` behind a tool binding must decide
what the user-visible behavior should be when this happens.

## Handling the constraint

Three options, in increasing cost/complexity:

### 1. Serialize at the consumer

Add a simple `Future`-chain lock in your tool executor. Each
invocation awaits the previous one's completion before calling
`runtime.execute()`:

```dart
class MyToolBinding {
  MontyRuntime _runtime;
  Future<void> _executionLock = Future<void>.value();

  Future<ToolResult> runPython(String code) async {
    final previous = _executionLock;
    final completer = Completer<void>();
    _executionLock = completer.future;
    try {
      // Wait for any in-flight execution. Swallow errors so a prior
      // failure does not block this call.
      try {
        await previous;
      } on Object {
        // Prior call's error is reported through its own result.
      }
      final handle = _runtime.execute(code);
      final result = await handle.result;
      return ToolResult.ok(result);
    } finally {
      completer.complete();
    }
  }
}
```

This is the recommended pattern for LLM tool bindings. It keeps
dart_monty's one-at-a-time contract honest upstream, while giving
the agent a "tool calls always complete" guarantee.

### 2. Return a "busy, retry" payload

Instead of queueing, catch the `StateError` and surface it to the
LLM as a structured "busy" result. The model can decide to retry.
Useful when you explicitly want backpressure visible to the planner
rather than hidden behind a queue.

### 3. Spawn a fresh runtime per request

Each tool call gets its own short-lived `MontyRuntime`. Removes the
serialization constraint entirely.

**Cost.** Construction is cheap — `MontyRuntime()` on native FFI
measures ~9 μs, and a full `construct → execute('1+1') → dispose`
lifecycle is ~132 μs, only ~52 μs more than a reused `execute`
(~80 μs). For tool calls that take milliseconds to seconds of actual
Python work, the overhead is noise. WASM cost is comparable in the
steady state once the WASM module is instantiated — construction
allocates a fresh `MontyRepl` handle, not a new worker.

**Built-in: `MontyRuntime(sandbox: true)`.** The library already has
a sandbox mode that creates a fresh `MontyRepl` per `execute()`
call. State does not persist between calls, and the shared-REPL
serialization constraint does not apply because each call gets its
own bridge. Prefer this over spinning up a whole new `MontyRuntime`
per invocation:

```dart
final runtime = MontyRuntime(
  extensions: [...],
  sandbox: true, // fresh MontyRepl per execute()
);
// Parallel execute calls work because each gets its own REPL +
// bridge; the _isExecuting guard is scoped per-bridge.
final results = await Future.wait([
  runtime.execute('expensive_a()').result,
  runtime.execute('expensive_b()').result,
]);
```

Only choose option 1 (serialization) over sandbox mode when you
explicitly need state to persist across calls — e.g. a REPL
conversation where `x = 42` in one tool call must be visible to the
next.

## Why not serialize inside `MontyRuntime`?

The `one at a time` guard lives in `PlatformBridge` on purpose:

- A stream-based API (`execute` returns `Stream<BridgeEvent>`) that
  silently buffered overlapping calls would make back-pressure
  invisible to consumers, producing mysterious latency spikes.
- Different consumers want different policies (queue vs. reject vs.
  surface-to-LLM); forcing one choice into the runtime rules out
  the other two.
- The native FFI backend has additional constraints (e.g. oracle
  subprocess synchronization during conformance tests) that make
  "single execute in flight" the natural invariant.

Consumers that want queueing implement the pattern above; the
library does not.

## See also

- [Lifecycles](lifecycles.md) — construction, attach, dispose
  ordering for `MontyRuntime` and its extensions.
- [Extension system](extension-system.md) — how extensions see
  execution events.
